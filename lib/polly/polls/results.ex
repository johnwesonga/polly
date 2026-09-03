defmodule Polly.Polls.Results do
  @moduledoc "Builds poll-scoped result and turnout projections."

  require Ash.Query

  alias Polly.Polls.{Ballot, Eligibility, Integrity, Option, Participation, Poll, Selection}

  @type option_result :: %{
          option: Option.t(),
          votes: non_neg_integer(),
          percentage: float(),
          rank: pos_integer() | nil,
          winner?: boolean()
        }

  @type t :: %{
          poll: Poll.t(),
          selection_mode: :single | :multiple,
          options: [option_result()],
          total_selections: non_neg_integer(),
          ballot_count: non_neg_integer(),
          participation_count: non_neg_integer(),
          integrity: Integrity.check(),
          eligible_count: non_neg_integer(),
          turnout_percentage: float(),
          winner_labels: [String.t()]
        }

  @spec for_poll(Poll.t() | Ecto.UUID.t()) :: t()
  def for_poll(%Poll{} = poll), do: build(poll)

  def for_poll(poll_id) do
    poll_id
    |> then(&Ash.get!(Poll, &1, authorize?: false))
    |> build()
  end

  @doc "Calculates turnout using the same rounding semantics as poll results."
  @spec turnout_percentage(non_neg_integer(), non_neg_integer()) :: float()
  def turnout_percentage(_ballot_count, 0), do: 0.0

  def turnout_percentage(ballot_count, eligible_count),
    do: percentage(ballot_count, eligible_count)

  defp build(poll) do
    options = list_options(poll.id)
    vote_counts = vote_counts(poll.id)
    total_selections = vote_counts |> Map.values() |> Enum.sum()
    ballot_count = count_ballots(poll.id)
    participation_count = count_participations(poll.id)
    integrity = Integrity.compare(poll, participation_count, ballot_count)
    eligible_count = count_eligible(poll.id)
    highest_count = vote_counts |> Map.values() |> Enum.max(fn -> 0 end)

    option_results =
      options
      |> Enum.map(fn option ->
        votes = Map.get(vote_counts, option.id, 0)

        %{
          option: option,
          votes: votes,
          percentage: percentage(votes, ballot_count),
          rank: rank(vote_counts, votes, ballot_count),
          winner?: ballot_count > 0 and votes == highest_count
        }
      end)
      |> Enum.sort_by(&{-&1.votes, &1.option.position})

    %{
      poll: poll,
      selection_mode: poll.selection_mode,
      options: option_results,
      total_selections: total_selections,
      ballot_count: ballot_count,
      participation_count: participation_count,
      integrity: integrity,
      eligible_count: eligible_count,
      turnout_percentage: turnout_percentage(participation_count, eligible_count),
      winner_labels:
        option_results
        |> Enum.filter(& &1.winner?)
        |> Enum.map(& &1.option.label)
    }
  end

  defp list_options(poll_id) do
    Option
    |> Ash.Query.filter(poll_id == ^poll_id and active == true)
    |> Ash.Query.sort(position: :asc)
    |> Ash.read!(authorize?: false)
  end

  defp vote_counts(poll_id) do
    Selection
    |> Ash.Query.filter(ballot.poll_id == ^poll_id)
    |> Ash.read!(authorize?: false)
    |> Enum.frequencies_by(& &1.option_id)
  end

  defp count_ballots(poll_id) do
    Ballot
    |> Ash.Query.filter(poll_id == ^poll_id)
    |> Ash.count!(authorize?: false)
  end

  defp count_participations(poll_id) do
    Participation
    |> Ash.Query.filter(poll_id == ^poll_id)
    |> Ash.count!(authorize?: false)
  end

  defp count_eligible(poll_id) do
    Eligibility
    |> Ash.Query.filter(poll_id == ^poll_id)
    |> Ash.count!(authorize?: false)
  end

  defp rank(_counts, _votes, 0), do: nil

  defp rank(counts, votes, _ballot_count) do
    1 + Enum.count(counts, fn {_option_id, count} -> count > votes end)
  end

  defp percentage(_part, 0), do: 0.0
  defp percentage(part, whole), do: Float.round(part / whole * 100, 1)
end
