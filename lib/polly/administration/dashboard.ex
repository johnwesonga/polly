defmodule Polly.Administration.Dashboard do
  @moduledoc "Permission-aware projections for the administration dashboard."

  require Ash.Query

  alias Polly.Accounts.{Authorization, User}
  alias Polly.Audit.Event
  alias Polly.Polls.Integrity

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

  @type scheduled_transition :: %{
          id: Ecto.UUID.t(),
          poll_id: Ecto.UUID.t(),
          poll_title: String.t(),
          opening_at: DateTime.t() | nil,
          closing_at: DateTime.t() | nil,
          destination: String.t()
        }

  @spec load(User.t()) ::
          {:ok,
           %{
             poll_counts: poll_counts(),
             attention_items: [attention_item()],
             active_polls: [active_poll()],
             scheduled_transitions: [scheduled_transition()] | nil,
             recent_events: [Event.t()] | nil,
             account_health: account_health() | nil
           }}
          | {:error, :forbidden}
  def load(%User{} = actor) do
    with :ok <- Authorization.authorize(actor, :view_results),
         {:ok, integrity_issues} <- Integrity.scan(actor) do
      {:ok,
       %{
         poll_counts: poll_counts(),
         attention_items: attention_items(actor, length(integrity_issues)),
         active_polls: active_polls(actor),
         scheduled_transitions: scheduled_transitions(actor),
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

  defp attention_items(actor, integrity_issue_count) do
    {:ok, counts} = Polly.Polls.Readiness.attention_counts(actor)
    lifecycle_failure_count = lifecycle_failure_count(actor)

    manager_items =
      if Authorization.allowed?(actor, :manage_polls) do
        [
          item(:missing_options, counts.missing_options, "/admin/polls?status=draft"),
          item(:missing_electorate, counts.missing_electorate, "/admin/polls?status=draft"),
          item(:unsent_invitations, counts.unsent_invitations, "/admin/polls?status=open"),
          item(:failed_deliveries, counts.failed_deliveries, "/admin/polls?status=open"),
          item(:failed_lifecycle_transitions, lifecycle_failure_count, "/admin/polls")
        ]
      else
        []
      end

    (manager_items ++
       [
         item(:integrity_issues, integrity_issue_count, "/admin/polls"),
         item(:unpublished_results, counts.unpublished_results, "/admin/polls?status=closed")
       ])
    |> Enum.reject(&is_nil/1)
  end

  defp item(_kind, 0, _destination), do: nil
  defp item(_kind, nil, _destination), do: nil
  defp item(kind, count, destination), do: %{kind: kind, count: count, destination: destination}

  defp lifecycle_failure_count(actor) do
    if Authorization.any_allowed?(actor, [:manage_polls, :publish_results]) do
      %{rows: [[count]]} =
        Polly.Repo.query!("""
        SELECT COUNT(*)
        FROM poll_lifecycle_transitions failed
        JOIN polls poll ON poll.id = failed.poll_id
        WHERE failed.state = 'failed'
          AND ((failed.kind = 'open' AND poll.status = 'draft')
            OR (failed.kind = 'close' AND poll.status IN ('draft', 'open')))
          AND NOT EXISTS (
            SELECT 1
            FROM poll_lifecycle_transitions newer
            WHERE newer.poll_id = failed.poll_id
              AND newer.kind = failed.kind
              AND newer.inserted_at > failed.inserted_at
              AND newer.state IN ('pending', 'completed')
          )
        """)

      count
    end
  end

  defp scheduled_transitions(actor) do
    if Authorization.any_allowed?(actor, [:manage_polls, :publish_results]) do
      %{rows: rows} =
        Polly.Repo.query!("""
        WITH next_polls AS (
          SELECT poll_id, MIN(scheduled_at) AS next_at
          FROM poll_lifecycle_transitions
          WHERE state = 'pending'
          GROUP BY poll_id
          ORDER BY next_at ASC, poll_id ASC
          LIMIT 5
        )
        SELECT transition.id, transition.poll_id, poll.title,
               transition.kind, transition.scheduled_at, next_polls.next_at
        FROM poll_lifecycle_transitions transition
        JOIN next_polls ON next_polls.poll_id = transition.poll_id
        JOIN polls poll ON poll.id = transition.poll_id
        WHERE transition.state = 'pending'
        ORDER BY next_polls.next_at ASC, transition.poll_id ASC,
                 transition.scheduled_at ASC, transition.id ASC
        """)

      Enum.reduce(rows, [], &group_scheduled_transition/2)
    end
  end

  defp group_scheduled_transition(
         [_id, poll_id, poll_title, kind, scheduled_at, _next_at],
         schedules
       ) do
    scheduled_at = parse_datetime(scheduled_at)

    case Enum.find_index(schedules, &(&1.poll_id == poll_id)) do
      nil ->
        schedule = %{
          id: poll_id,
          poll_id: poll_id,
          poll_title: poll_title,
          opening_at: if(kind == "open", do: scheduled_at),
          closing_at: if(kind == "close", do: scheduled_at),
          destination: "/admin/polls/#{poll_id}/lifecycle"
        }

        schedules ++ [schedule]

      index ->
        List.update_at(schedules, index, fn schedule ->
          case kind do
            "open" -> %{schedule | opening_at: scheduled_at}
            "close" -> %{schedule | closing_at: scheduled_at}
          end
        end)
    end
  end

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
