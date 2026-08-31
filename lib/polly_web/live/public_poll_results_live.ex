defmodule PollyWeb.PublicPollResultsLive do
  use PollyWeb, :live_view

  alias Polly.Polls.{Events, PublicResults, SelectionRules}

  @impl true
  def mount(%{"slug" => slug}, _session, socket) do
    case PublicResults.fetch_by_slug(slug) do
      {:ok, result} ->
        if connected?(socket), do: Events.subscribe(result.poll_id)

        {:ok,
         socket
         |> stream_configure(:results, dom_id: &"public-result-#{&1.id}")
         |> assign(:page_title, "#{result.title} results")
         |> assign(:slug, slug)
         |> assign(:result, result)
         |> assign(:summary, leading_summary(result))
         |> stream(:results, result.options)}

      {:error, :not_found} ->
        raise PollyWeb.NotFoundError
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <section id="public-results-page" class="member-wrap public-vote-page">
        <div class="phone vote-card public-results-card">
          <div class="phone-notch" aria-hidden="true"></div>
          <div class="phone-screen">
            <div class="m-eyebrow published-results-eyebrow">
              Published results · {format_date(@result.results_published_at)}
            </div>
            <div class="m-results-hero">
              <h1 class="m-title">{@result.title}</h1>
              <p :if={@result.description} class="m-desc">{@result.description}</p>
              <div :if={@summary} id="public-results-summary" class="v">{@summary}</div>
              <div class="laneline results-laneline"></div>
              <div class="published-turnout">
                {@result.ballot_count} of {@result.eligible_count} members voted · {format_percentage(
                  @result.turnout_percentage
                )} turnout
              </div>
              <div
                :if={@result.selection_mode == :multiple}
                id="public-total-selections"
                class="published-turnout"
              >
                {@result.total_selections} total selections
              </div>
            </div>

            <p id="public-selection-rules" class="vote-selection-instructions">
              {SelectionRules.summary(selection_rule_poll(@result))}.
            </p>
            <p id="public-results-explanation" class="m-fine">
              {percentage_explanation(@result.selection_mode)}
            </p>

            <div id="public-results" phx-update="stream">
              <div id="public-results-empty" class="empty-state hidden only:block">
                <h2>No results available</h2>
              </div>
              <div
                :for={{id, row} <- @streams.results}
                id={id}
                class={["m-result-row", row.leading? && "win"]}
              >
                <div class="m-result-top">
                  <b>{row.label}</b>
                  <span>{result_value(row, @result.selection_mode)}</span>
                </div>
                <div class="m-result-track">
                  <div class="m-result-fill" style={"width: #{row.percentage}%"}></div>
                </div>
              </div>
            </div>

            <p class="m-fine public-results-privacy">
              This page contains aggregate results only. It does not identify individual voters.
            </p>
          </div>
        </div>
      </section>
    </Layouts.app>
    """
  end

  @impl true
  def handle_info({:poll_status_changed, poll_id, _status, _published_at}, socket)
      when poll_id == socket.assigns.result.poll_id do
    case PublicResults.fetch_by_slug(socket.assigns.slug) do
      {:ok, result} ->
        {:noreply,
         socket
         |> assign(:result, result)
         |> assign(:summary, leading_summary(result))
         |> stream(:results, result.options, reset: true)}

      {:error, :not_found} ->
        {:noreply, push_navigate(socket, to: ~p"/polls/#{socket.assigns.slug}/results")}
    end
  end

  defp leading_summary(%{ballot_count: 0}), do: nil

  defp leading_summary(%{selection_mode: :multiple, leading_labels: [label]}),
    do: "Most selected: #{label}"

  defp leading_summary(%{selection_mode: :multiple, leading_labels: labels}),
    do: "Most selected (tie): #{Enum.join(labels, " · ")}"

  defp leading_summary(%{leading_labels: [label]}), do: "Leading: #{label}"
  defp leading_summary(%{leading_labels: labels}), do: "Tie: #{Enum.join(labels, " · ")}"

  defp percentage_explanation(:multiple),
    do:
      "Percentages show the share of submitted ballots selecting each option and may total more than 100%."

  defp percentage_explanation(:single),
    do: "Percentages show each option's share of submitted ballots."

  defp result_value(row, :multiple),
    do: "#{row.selections} · selected by #{format_percentage(row.percentage)}"

  defp result_value(row, :single),
    do: "#{row.selections} · #{format_percentage(row.percentage)}"

  defp selection_rule_poll(result) do
    %Polly.Polls.Poll{
      selection_mode: result.selection_mode,
      minimum_selections: result.minimum_selections,
      maximum_selections: result.maximum_selections
    }
  end

  defp format_percentage(value), do: :erlang.float_to_binary(value, decimals: 1) <> "%"
  defp format_date(nil), do: ""
  defp format_date(datetime), do: Calendar.strftime(datetime, "%b %-d, %Y")
end
