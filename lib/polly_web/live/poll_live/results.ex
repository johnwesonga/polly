defmodule PollyWeb.PollLive.Results do
  use PollyWeb, :live_view

  alias Polly.Polls.{Duplicator, Events, Poll}
  alias Polly.Polls.Results, as: PollResults

  on_mount {PollyWeb.LiveUserAuth, :live_user_required}

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    actor = socket.assigns.current_user
    poll = Ash.get!(Poll, id, actor: actor)

    if connected?(socket), do: Events.subscribe(poll.id)

    {:ok,
     socket
     |> stream_configure(:results, dom_id: &"result-#{&1.option.id}")
     |> assign(:page_title, "#{poll.title} results")
     |> assign(:poll, poll)
     |> load_results()}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} active_nav={:polls}>
      <section id="poll-results-page">
        <div class="breadcrumb">
          <.link navigate={~p"/admin/polls"}>Polls</.link><span>/</span><span>{@poll.title}</span>
        </div>
        <div class="detail-header">
          <div>
            <div class="admin-h2">{String.upcase(@poll.title)}</div>
            <p class="admin-sub" style="margin:4px 0 0;">
              Monitor turnout, review poll-scoped results, and control publication.
            </p>
          </div>
          <span id="poll-results-status" class={"pill #{@poll.status}"}>{@poll.status}</span>
        </div>

        <div class="detail-tabs" aria-label="Poll configuration sections">
          <.link navigate={~p"/admin/polls/#{@poll.id}/options"} class="phase-tab">Options</.link>
          <.link navigate={~p"/admin/polls/#{@poll.id}/electorate"} class="phase-tab">
            Electorate
          </.link>
          <.link navigate={~p"/admin/polls/#{@poll.id}/access"} class="phase-tab">
            Access links
          </.link>
          <span class="phase-tab current">Results</span>
        </div>

        <div id="poll-lifecycle-controls" class="card card-pad lifecycle-card">
          <div>
            <h3>Poll lifecycle</h3>
            <p class="admin-sub lifecycle-copy">{lifecycle_copy(@poll)}</p>
          </div>
          <button
            :if={@poll.status == :draft}
            id="open-poll-button"
            type="button"
            phx-click="open"
            data-confirm="Open this poll? Options and electorate will be frozen."
            class="btn btn-coral"
          >
            Open poll
          </button>
          <button
            :if={@poll.status == :open}
            id="close-poll-button"
            type="button"
            phx-click="close"
            data-confirm="Close this poll? No more ballots will be accepted."
            class="btn btn-ghost close-poll-button"
          >
            Close poll
          </button>
          <button
            :if={@poll.status == :closed && is_nil(@poll.results_published_at)}
            id="publish-results-button"
            type="button"
            phx-click="publish"
            data-confirm="Publish these final results to members?"
            class="btn btn-coral"
          >
            Publish results
          </button>
          <span
            :if={@poll.results_published_at}
            id="results-published-status"
            class="pill published"
          >
            Published
          </span>
          <button
            id="duplicate-poll-button"
            type="button"
            phx-click="duplicate"
            data-confirm={
              "Duplicate #{@poll.title}? Only its title, description, and selection mode will be copied into a new draft."
            }
            class="btn btn-outline"
          >
            Duplicate poll
          </button>
        </div>

        <div class="result-metrics">
          <div class="card card-pad metric-card">
            <span>Ballots</span>
            <strong id="ballot-count">{@result.ballot_count}</strong>
          </div>
          <div class="card card-pad metric-card">
            <span>Eligible members</span>
            <strong id="eligible-count">{@result.eligible_count}</strong>
          </div>
          <div class="card card-pad metric-card">
            <span>Turnout</span>
            <strong id="turnout-percentage">{format_percentage(@result.turnout_percentage)}</strong>
          </div>
        </div>

        <div class="card card-pad">
          <div class="results-heading">
            <h3>Results</h3>
            <span :if={@winner_summary} id="winner-summary" class="poll-meta">
              {@winner_summary}
            </span>
          </div>
          <div id="poll-results" phx-update="stream">
            <div id="poll-results-empty" class="empty-state hidden only:block">
              <h2>No active options</h2>
              <p>Configure ballot options before opening this poll.</p>
            </div>
            <div
              :for={{id, row} <- @streams.results}
              id={id}
              class={["result-row", row.winner? && "win"]}
            >
              <div class="result-top">
                <span class="result-name">
                  <span :if={row.rank} class="result-rank">#{row.rank}</span>
                  {row.option.label}
                </span>
                <span class="result-num">
                  {row.votes} · {format_percentage(row.percentage)}
                </span>
              </div>
              <div class="result-track">
                <div class="result-fill" style={"width: #{row.percentage}%"}></div>
              </div>
            </div>
          </div>
        </div>
      </section>
    </Layouts.app>
    """
  end

  @impl true
  def handle_event("open", _params, socket), do: transition(socket, :open, "Poll opened")
  def handle_event("close", _params, socket), do: transition(socket, :close, "Poll closed")

  def handle_event("publish", _params, socket),
    do: transition(socket, :publish_results, "Results published")

  def handle_event("duplicate", _params, socket) do
    case Duplicator.duplicate(socket.assigns.poll, socket.assigns.current_user) do
      {:ok, %{poll: duplicate}} ->
        {:noreply,
         socket
         |> put_flash(:info, "Draft duplicated from #{socket.assigns.poll.title}")
         |> push_navigate(to: ~p"/admin/polls/#{duplicate.id}/edit")}

      {:error, error} ->
        {:noreply, put_flash(socket, :error, duplicate_error(error))}
    end
  end

  @impl true
  def handle_info({:poll_results_changed, poll_id}, %{assigns: %{poll: %{id: poll_id}}} = socket) do
    {:noreply, load_results(socket)}
  end

  def handle_info(
        {:poll_status_changed, poll_id, _status, _published_at},
        %{assigns: %{poll: %{id: poll_id}}} = socket
      ) do
    {:noreply, reload_poll(socket)}
  end

  defp transition(socket, action, message) do
    case Ash.update(socket.assigns.poll, %{}, action: action, actor: socket.assigns.current_user) do
      {:ok, poll} ->
        {:noreply,
         socket
         |> assign(:poll, poll)
         |> put_flash(:info, message)
         |> load_results()}

      {:error, error} ->
        {:noreply, put_flash(socket, :error, Exception.message(error))}
    end
  end

  defp reload_poll(socket) do
    poll = Ash.get!(Poll, socket.assigns.poll.id, actor: socket.assigns.current_user)
    socket |> assign(:poll, poll) |> load_results()
  end

  defp load_results(socket) do
    result = PollResults.for_poll(socket.assigns.poll)

    socket
    |> assign(:result, result)
    |> assign(:winner_summary, winner_summary(result))
    |> stream(:results, result.options, reset: true)
  end

  defp winner_summary(%{ballot_count: 0}), do: nil
  defp winner_summary(%{winner_labels: [winner]}), do: "Leading: #{winner}"
  defp winner_summary(%{winner_labels: winners}), do: "Tie: #{Enum.join(winners, " · ")}"

  defp lifecycle_copy(%Poll{status: :draft}),
    do: "Opening freezes options and electorate and makes private voting links live."

  defp lifecycle_copy(%Poll{status: :open}),
    do: "Voting is live. Closing is final and immediately stops new submissions."

  defp lifecycle_copy(%Poll{results_published_at: published_at}) when not is_nil(published_at),
    do: "Final results are visible to members with valid access links."

  defp lifecycle_copy(%Poll{status: :closed}),
    do: "Voting is closed. Review the final totals before publishing them to members."

  defp format_percentage(value), do: :erlang.float_to_binary(value, decimals: 1) <> "%"

  defp duplicate_error(:actor_required), do: "You must sign in to duplicate a poll"
  defp duplicate_error(:slug_generation_exhausted), do: "Could not generate a unique poll slug"
  defp duplicate_error(error), do: Exception.message(error)
end
