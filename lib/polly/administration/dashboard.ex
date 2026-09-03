defmodule Polly.Administration.Dashboard do
  @moduledoc "Permission-aware projections for the administration dashboard."

  require Ash.Query

  alias Polly.Accounts.{Authorization, User}
  alias Polly.Audit.Event

  @type poll_counts :: %{
          draft: non_neg_integer(),
          open: non_neg_integer(),
          closed: non_neg_integer(),
          unpublished: non_neg_integer()
        }

  @type attention_item :: %{
          kind: atom(),
          count: pos_integer(),
          destination: String.t()
        }

  @type active_poll :: %{
          id: Ecto.UUID.t(),
          title: String.t(),
          opened_at: DateTime.t() | nil,
          participation_count: non_neg_integer(),
          eligible_count: non_neg_integer(),
          turnout_percentage: float(),
          accepted_deliveries: non_neg_integer(),
          pending_deliveries: non_neg_integer(),
          failed_deliveries: non_neg_integer(),
          destination: String.t()
        }

  @type account_health :: %{
          active_owners: non_neg_integer(),
          disabled_accounts: non_neg_integer(),
          unconfirmed_accounts: non_neg_integer(),
          pending_invitations: non_neg_integer(),
          expiring_invitations: non_neg_integer(),
          final_owner?: boolean()
        }

  @spec load(User.t()) ::
          {:ok,
           %{
             poll_counts: poll_counts(),
             attention_items: [attention_item()],
             active_polls: [active_poll()],
             recent_events: [Event.t()] | nil,
             account_health: account_health() | nil
           }}
          | {:error, :forbidden}
  def load(%User{} = actor) do
    with :ok <- Authorization.authorize(actor, :view_results) do
      {:ok,
       %{
         poll_counts: poll_counts(),
         attention_items: attention_items(actor),
         active_polls: active_polls(actor),
         recent_events: recent_events(actor),
         account_health: account_health(actor)
       }}
    end
  end

  def load(_actor), do: {:error, :forbidden}

  defp recent_events(actor) do
    if Authorization.allowed?(actor, :view_audit) do
      page =
        Event
        |> Ash.Query.sort(occurred_at: :desc, id: :desc)
        |> Ash.read!(actor: actor, page: [limit: 5])

      page.results
    end
  end

  defp account_health(actor) do
    if Authorization.allowed?(actor, :manage_administrators) do
      now = DateTime.utc_now()
      expiring_before = DateTime.add(now, 48, :hour)

      %{rows: [[owners, disabled, unconfirmed, pending, expiring]]} =
        Polly.Repo.query!(
          """
          SELECT
            (SELECT COUNT(*) FROM users
             WHERE role = 'owner' AND status = 'active'),
            (SELECT COUNT(*) FROM users
             WHERE status = 'disabled'),
            (SELECT COUNT(*) FROM users
             WHERE confirmed_at IS NULL),
            (SELECT COUNT(*) FROM administrator_invitations
             WHERE status = 'pending' AND expires_at > ?),
            (SELECT COUNT(*) FROM administrator_invitations
             WHERE status = 'pending' AND expires_at > ? AND expires_at <= ?)
          """,
          [now, now, expiring_before]
        )

      %{
        active_owners: owners,
        disabled_accounts: disabled,
        unconfirmed_accounts: unconfirmed,
        pending_invitations: pending,
        expiring_invitations: expiring,
        final_owner?: owners == 1
      }
    end
  end

  defp poll_counts do
    %{rows: [[draft, open, closed, unpublished]]} =
      Polly.Repo.query!("""
      SELECT
        COALESCE(SUM(CASE WHEN status = 'draft' THEN 1 ELSE 0 END), 0),
        COALESCE(SUM(CASE WHEN status = 'open' THEN 1 ELSE 0 END), 0),
        COALESCE(SUM(CASE WHEN status = 'closed' THEN 1 ELSE 0 END), 0),
        COALESCE(SUM(CASE WHEN status = 'closed' AND results_published_at IS NULL THEN 1 ELSE 0 END), 0)
      FROM polls
      """)

    %{draft: draft, open: open, closed: closed, unpublished: unpublished}
  end

  defp attention_items(actor) do
    {:ok, counts} = Polly.Polls.Readiness.attention_counts(actor)

    manager_items =
      if Authorization.allowed?(actor, :manage_polls) do
        [
          item(:missing_options, counts.missing_options, "/admin/polls?status=draft"),
          item(:missing_electorate, counts.missing_electorate, "/admin/polls?status=draft"),
          item(:unsent_invitations, counts.unsent_invitations, "/admin/polls?status=open"),
          item(:failed_deliveries, counts.failed_deliveries, "/admin/polls?status=open")
        ]
      else
        []
      end

    (manager_items ++
       [item(:unpublished_results, counts.unpublished_results, "/admin/polls?status=closed")])
    |> Enum.reject(&is_nil/1)
  end

  defp item(_kind, 0, _destination), do: nil
  defp item(_kind, nil, _destination), do: nil
  defp item(kind, count, destination), do: %{kind: kind, count: count, destination: destination}

  defp active_polls(actor) do
    destination =
      if Authorization.allowed?(actor, :manage_access_grants),
        do: :access,
        else: :results

    %{rows: rows} =
      Polly.Repo.query!("""
      WITH active_polls AS (
        SELECT id, title, opened_at, updated_at
        FROM polls
        WHERE status = 'open'
        ORDER BY updated_at DESC, title ASC
        LIMIT 5
      )
      SELECT
        p.id,
        p.title,
        p.opened_at,
        (SELECT COUNT(*) FROM poll_participations participation WHERE participation.poll_id = p.id),
        (SELECT COUNT(*) FROM poll_eligibilities e WHERE e.poll_id = p.id),
        (SELECT COUNT(*) FROM poll_invitation_deliveries d
         WHERE d.poll_id = p.id AND d.status = 'accepted'),
        (SELECT COUNT(*) FROM poll_invitation_deliveries d
         WHERE d.poll_id = p.id AND d.status IN ('queued', 'sending')),
        (SELECT COUNT(*) FROM poll_invitation_deliveries d
         WHERE d.poll_id = p.id AND d.status = 'failed')
      FROM active_polls p
      ORDER BY p.updated_at DESC, p.title ASC
      """)

    Enum.map(rows, fn [id, title, opened_at, participations, eligible, accepted, pending, failed] ->
      %{
        id: id,
        title: title,
        opened_at: parse_datetime(opened_at),
        participation_count: participations,
        eligible_count: eligible,
        turnout_percentage: Polly.Polls.Results.turnout_percentage(participations, eligible),
        accepted_deliveries: accepted,
        pending_deliveries: pending,
        failed_deliveries: failed,
        destination: "/admin/polls/#{id}/#{destination}"
      }
    end)
  end

  defp parse_datetime(%DateTime{} = datetime), do: datetime

  defp parse_datetime(%NaiveDateTime{} = datetime),
    do: DateTime.from_naive!(datetime, "Etc/UTC")

  defp parse_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} ->
        datetime

      {:error, _reason} ->
        value
        |> NaiveDateTime.from_iso8601!()
        |> DateTime.from_naive!("Etc/UTC")
    end
  end

  defp parse_datetime(nil), do: nil
end
