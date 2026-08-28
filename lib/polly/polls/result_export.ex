defmodule Polly.Polls.ResultExport do
  @moduledoc "Generates an authorized, aggregate CSV snapshot of one poll's results."

  alias Polly.Accounts.User
  alias Polly.Polls.{Poll, ResultCSV, Results}

  @headers ~w(
    poll_id
    poll_title
    poll_status
    result_state
    selection_mode
    minimum_selections
    maximum_selections
    eligible_members
    ballots_submitted
    turnout_percentage
    total_selections
    option_position
    option_label
    selection_count
    percentage_of_ballots
    rank
    leading
    exported_at
  )

  @type export :: %{
          iodata: iodata(),
          filename: String.t(),
          row_count: non_neg_integer(),
          result_state: String.t()
        }

  @spec generate(Ecto.UUID.t(), keyword()) :: {:ok, export()} | {:error, term()}
  def generate(poll_id, opts) when is_binary(poll_id) and is_list(opts) do
    started_at = System.monotonic_time()
    actor = Keyword.get(opts, :actor)
    now = Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)
    request_id = Keyword.get(opts, :request_id)

    result = generate_export(poll_id, actor, now, request_id)

    {status, row_count, result_state} =
      case result do
        {:ok, export} -> {:ok, export.row_count, export.result_state}
        {:error, _reason} -> {:error, 0, nil}
      end

    :telemetry.execute(
      [:polly, :polls, :result_export],
      %{duration: System.monotonic_time() - started_at, row_count: row_count},
      %{poll_id: poll_id, status: status, result_state: result_state}
    )

    result
  end

  def generate(_poll_id, _opts), do: {:error, :invalid_request}

  defp generate_export(_poll_id, actor, _now, _request_id) when not is_struct(actor, User),
    do: {:error, :unauthorized}

  defp generate_export(poll_id, actor, now, request_id) do
    with :ok <- Polly.Accounts.Authorization.authorize(actor, :export_results),
         {:ok, poll} <- Ash.get(Poll, poll_id, actor: actor),
         :ok <- exportable?(poll),
         result <- Results.for_poll(poll),
         :ok <- has_options?(result),
         result_state <- result_state(poll),
         rows <- rows(poll, result, result_state, now),
         :ok <- append_audit(poll, result, result_state, actor, request_id) do
      {:ok,
       %{
         iodata: ResultCSV.dump_to_iodata([@headers | rows]),
         filename: filename(poll, now),
         row_count: length(rows),
         result_state: result_state
       }}
    else
      {:error, %Ash.Error.Invalid{}} -> {:error, :not_found}
      {:error, %Ash.Error.Forbidden{}} -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  defp exportable?(%Poll{status: :draft}), do: {:error, :poll_not_open}
  defp exportable?(%Poll{}), do: :ok

  defp has_options?(%{options: []}), do: {:error, :no_options}
  defp has_options?(_result), do: :ok

  defp rows(poll, result, result_state, now) do
    total_selections = Enum.sum(Enum.map(result.options, & &1.votes))
    exported_at = DateTime.to_iso8601(now)

    result.options
    |> Enum.sort_by(fn row ->
      {row.rank || 2_147_483_647, -row.votes, row.option.position, row.option.id}
    end)
    |> Enum.map(fn row ->
      [
        poll.id,
        safe_text(poll.title),
        to_string(poll.status),
        result_state,
        to_string(poll.selection_mode),
        poll_limit(poll, :minimum_selections),
        poll_limit(poll, :maximum_selections),
        result.eligible_count,
        result.ballot_count,
        decimal(result.turnout_percentage),
        total_selections,
        row.option.position,
        safe_text(row.option.label),
        row.votes,
        decimal(row.percentage),
        row.rank || "",
        row.winner?,
        exported_at
      ]
      |> Enum.map(&to_string/1)
    end)
  end

  defp poll_limit(poll, key), do: Map.get(poll, key, 1)

  defp safe_text(value) do
    if Regex.match?(~r/^\s*[=+\-@]/u, value), do: "'" <> value, else: value
  end

  defp decimal(value), do: :erlang.float_to_binary(value, decimals: 1)

  defp result_state(%Poll{status: :open}), do: "provisional"

  defp result_state(%Poll{status: :closed, results_published_at: nil}),
    do: "final_unpublished"

  defp result_state(%Poll{status: :closed}), do: "final_published"

  defp filename(poll, now) do
    "#{poll.slug}-results-#{now |> DateTime.to_date() |> Date.to_iso8601()}.csv"
  end

  defp append_audit(poll, result, result_state, actor, request_id) do
    case Polly.Audit.append(%{
           action: "poll.results_exported",
           actor: actor,
           target: %{type: "poll", id: poll.id, label: poll.title},
           poll_id: poll.id,
           request_id: request_id,
           metadata: %{
             poll_status: to_string(poll.status),
             result_state: result_state,
             option_count: length(result.options),
             submitted_count: result.ballot_count,
             eligible_count: result.eligible_count,
             provisional: result_state == "provisional"
           }
         }) do
      {:ok, _event} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end
end
