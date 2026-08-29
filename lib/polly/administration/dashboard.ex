defmodule Polly.Administration.Dashboard do
  @moduledoc "Permission-aware projections for the administration dashboard."

  alias Polly.Accounts.{Authorization, User}

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

  @spec load(User.t()) ::
          {:ok, %{poll_counts: poll_counts(), attention_items: [attention_item()]}}
          | {:error, :forbidden}
  def load(%User{} = actor) do
    with :ok <- Authorization.authorize(actor, :view_results) do
      {:ok,
       %{
         poll_counts: poll_counts(),
         attention_items: attention_items(actor)
       }}
    end
  end

  def load(_actor), do: {:error, :forbidden}

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
    counts = attention_counts()

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

  defp attention_counts do
    %{rows: [[missing_options, missing_electorate, unsent, failed, unpublished]]} =
      Polly.Repo.query!("""
      SELECT
        (SELECT COUNT(*) FROM polls p
         WHERE p.status = 'draft'
           AND (SELECT COUNT(*) FROM poll_options o WHERE o.poll_id = p.id AND o.active = 1) < 2),
        (SELECT COUNT(*) FROM polls p
         WHERE p.status = 'draft'
           AND NOT EXISTS (SELECT 1 FROM poll_eligibilities e WHERE e.poll_id = p.id)),
        (SELECT COUNT(*) FROM polls p
         WHERE p.status = 'open'
           AND NOT EXISTS (
             SELECT 1 FROM poll_invitation_deliveries d
             WHERE d.poll_id = p.id AND d.status = 'accepted'
           )),
        (SELECT COUNT(*) FROM polls p
         WHERE p.status = 'open'
           AND EXISTS (
             SELECT 1 FROM poll_invitation_deliveries d
             WHERE d.poll_id = p.id AND d.status = 'failed'
           )),
        (SELECT COUNT(*) FROM polls p
         WHERE p.status = 'closed' AND p.results_published_at IS NULL)
      """)

    %{
      missing_options: missing_options,
      missing_electorate: missing_electorate,
      unsent_invitations: unsent,
      failed_deliveries: failed,
      unpublished_results: unpublished
    }
  end

  defp item(_kind, 0, _destination), do: nil
  defp item(kind, count, destination), do: %{kind: kind, count: count, destination: destination}
end
