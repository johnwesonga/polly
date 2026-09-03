defmodule Polly.Polls.Integrity do
  @moduledoc """
  Detects aggregate participation and ballot count discrepancies.

  Integrity checks deliberately operate only on poll-level counts. They never
  attempt to correlate participation records with ballots or selections.
  """

  require Logger

  alias Polly.Accounts.Authorization
  alias Polly.Polls.Poll

  @type check :: %{
          poll_id: Ecto.UUID.t(),
          privacy_mode: :identified | :anonymous,
          participation_count: non_neg_integer(),
          ballot_count: non_neg_integer(),
          consistent?: boolean()
        }

  @doc "Returns and reports the aggregate integrity state for one poll."
  @spec compare(Poll.t(), non_neg_integer(), non_neg_integer()) :: check()
  def compare(%Poll{} = poll, participation_count, ballot_count) do
    check = %{
      poll_id: poll.id,
      privacy_mode: poll.privacy_mode,
      participation_count: participation_count,
      ballot_count: ballot_count,
      consistent?: participation_count == ballot_count
    }

    report(check)
    check
  end

  @doc "Lists polls whose aggregate participation and ballot counts differ."
  @spec scan(term()) :: {:ok, [check()]} | {:error, :forbidden}
  def scan(actor) do
    with :ok <- Authorization.authorize(actor, :view_results) do
      %{rows: rows} =
        Polly.Repo.query!("""
        SELECT
          p.id,
          p.privacy_mode,
          (SELECT COUNT(*) FROM poll_participations participation
           WHERE participation.poll_id = p.id),
          (SELECT COUNT(*) FROM poll_ballots ballot
           WHERE ballot.poll_id = p.id)
        FROM polls p
        WHERE
          (SELECT COUNT(*) FROM poll_participations participation
           WHERE participation.poll_id = p.id) !=
          (SELECT COUNT(*) FROM poll_ballots ballot
           WHERE ballot.poll_id = p.id)
        ORDER BY p.updated_at DESC, p.id DESC
        """)

      checks =
        Enum.map(rows, fn [poll_id, privacy_mode, participation_count, ballot_count] ->
          check = %{
            poll_id: poll_id,
            privacy_mode: privacy_mode(privacy_mode),
            participation_count: participation_count,
            ballot_count: ballot_count,
            consistent?: false
          }

          report(check)
          check
        end)

      {:ok, checks}
    end
  end

  defp privacy_mode("identified"), do: :identified
  defp privacy_mode("anonymous"), do: :anonymous

  defp report(%{consistent?: true}), do: :ok

  defp report(check) do
    Logger.warning("poll aggregate integrity mismatch",
      poll_id: check.poll_id,
      privacy_mode: check.privacy_mode,
      participation_count: check.participation_count,
      ballot_count: check.ballot_count
    )

    :telemetry.execute(
      [:polly, :polls, :integrity, :mismatch],
      %{
        participation_count: check.participation_count,
        ballot_count: check.ballot_count,
        difference: check.participation_count - check.ballot_count
      },
      %{poll_id: check.poll_id, privacy_mode: check.privacy_mode}
    )
  end
end
