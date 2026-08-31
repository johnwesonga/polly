defmodule Polly.Polls.PublicResults do
  @moduledoc "Builds the aggregate-only projection exposed by public result pages."

  require Ash.Query

  alias Polly.Polls.{Poll, Results}

  @type option_result :: %{
          id: Ecto.UUID.t(),
          label: String.t(),
          position: integer(),
          selections: non_neg_integer(),
          percentage: float(),
          rank: pos_integer() | nil,
          leading?: boolean()
        }

  @type t :: %{
          poll_id: Ecto.UUID.t(),
          slug: String.t(),
          title: String.t(),
          description: String.t() | nil,
          closed_at: DateTime.t() | nil,
          results_published_at: DateTime.t(),
          selection_mode: :single | :multiple,
          minimum_selections: pos_integer(),
          maximum_selections: pos_integer(),
          ballot_count: non_neg_integer(),
          eligible_count: non_neg_integer(),
          turnout_percentage: float(),
          total_selections: non_neg_integer(),
          leading_labels: [String.t()],
          options: [option_result()]
        }

  @spec fetch_by_slug(String.t()) :: {:ok, t()} | {:error, :not_found}
  def fetch_by_slug(slug) when is_binary(slug) do
    poll =
      Poll
      |> Ash.Query.filter(
        slug == ^slug and status == :closed and not is_nil(results_published_at) and
          result_visibility == :public
      )
      |> Ash.read_one!(authorize?: false)

    case poll do
      %Poll{} -> {:ok, project(poll)}
      nil -> {:error, :not_found}
    end
  end

  def fetch_by_slug(_slug), do: {:error, :not_found}

  defp project(poll) do
    result = Results.for_poll(poll)

    %{
      poll_id: poll.id,
      slug: poll.slug,
      title: poll.title,
      description: poll.description,
      closed_at: poll.closed_at,
      results_published_at: poll.results_published_at,
      selection_mode: result.selection_mode,
      minimum_selections: poll.minimum_selections,
      maximum_selections: poll.maximum_selections,
      ballot_count: result.ballot_count,
      eligible_count: result.eligible_count,
      turnout_percentage: result.turnout_percentage,
      total_selections: result.total_selections,
      leading_labels: result.winner_labels,
      options:
        Enum.map(result.options, fn row ->
          %{
            id: row.option.id,
            label: row.option.label,
            position: row.option.position,
            selections: row.votes,
            percentage: row.percentage,
            rank: row.rank,
            leading?: row.winner?
          }
        end)
    }
  end
end
