defmodule PollyWeb.PollLive.Results do
  @moduledoc """
  Presents live administrator results and poll lifecycle controls.

  The LiveView subscribes to poll events, renders mode-aware aggregate results,
  and exposes authorized actions for opening, closing, publishing, sharing, and
  exporting results.
  """

  use PollyWeb, :live_view

  alias Polly.Polls.{Events, Poll}
  alias Polly.Polls.Results, as: PollResults

  on_mount {PollyWeb.LiveUserAuth, {:require_permission, :view_results}}

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    actor = socket.assigns.current_user
    poll = Ash.get!(Poll, id, actor: actor)

    if connected?(socket), do: Events.subscribe(poll.id)

    {:ok,
     socket
     |> stream_configure(:results, dom_id: &"result-#{&1.option.id}")
     |> assign(:page_title, "#{poll.title} results")
     |> assign(:manage_polls?, Polly.Accounts.Authorization.allowed?(actor, :manage_polls))
     |> assign(:publish_results?, Polly.Accounts.Authorization.allowed?(actor, :publish_results))
     |> assign(:export_results?, Polly.Accounts.Authorization.allowed?(actor, :export_results))
     |> assign(:poll, poll)
     |> assign(:confirming_export?, false)
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
          <.link
            :if={@manage_polls?}
            navigate={~p"/admin/polls/#{@poll.id}/options"}
            class="phase-tab"
          >
            Options
          </.link>
          <.link
            :if={@manage_polls?}
            navigate={~p"/admin/polls/#{@poll.id}/electorate"}
            class="phase-tab"
          >
            Electorate
          </.link>
          <.link
            :if={@manage_polls?}
            navigate={~p"/admin/polls/#{@poll.id}/access"}
            class="phase-tab"
          >
            Voter access
          </.link>
          <span class="phase-tab current">Results</span>
        </div>

        <div id="poll-lifecycle-controls" class="card card-pad lifecycle-card">
          <div>
            <h3>Poll lifecycle</h3>
            <p class="admin-sub lifecycle-copy">{lifecycle_copy(@poll)}</p>
            <p :if={@poll.status == :open} id="poll-open-timing" class="poll-meta">
              {PollyWeb.PollTiming.summary(@poll.opened_at)}
            </p>
            <p
              :if={@poll.results_published_at}
              id="results-publication-timing"
              class="poll-meta"
            >
              {PollyWeb.PollTiming.publication_summary(@poll.results_published_at)}
            </p>
          </div>
          <button
            :if={@manage_polls? && @poll.status == :draft}
            id="open-poll-button"
            type="button"
            phx-click="open"
            data-confirm="Open this poll? Options and electorate will be frozen."
            class="btn btn-coral"
          >
            Open poll
          </button>
          <button
            :if={@publish_results? && @poll.status == :open}
            id="close-poll-button"
            type="button"
            phx-click="close"
            data-confirm="Close this poll? No more ballots will be accepted."
            class="btn btn-ghost close-poll-button"
          >
            Close poll
          </button>
          <button
            :if={@publish_results? && @poll.status == :closed && is_nil(@poll.results_published_at)}
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
          <.link
            :if={@manage_polls?}
            id="duplicate-poll-button"
            navigate={~p"/admin/polls/#{@poll.id}/duplicate"}
            class="btn btn-outline"
          >
            Duplicate poll
          </.link>
          <button
            :if={@export_results?}
            id="export-results-button"
            type="button"
            phx-click="prepare-export"
            disabled={@poll.status == :draft || @result.options == []}
            class="btn btn-outline"
          >
            Export results CSV
          </button>
        </div>

        <div :if={@poll.status == :closed} id="result-visibility" class="card card-pad lifecycle-card">
          <div>
            <h3>Results audience</h3>
            <p id="result-visibility-description" class="admin-sub lifecycle-copy">
              {visibility_copy(@poll)}
            </p>
            <div
              :if={public_results_available?(@poll)}
              id="public-results-link"
              class="access-link-controls"
            >
              <code class="access-url-preview" title={public_results_url(@poll)}>
                {public_results_url(@poll)}
              </code>
              <button
                id="copy-public-results-link"
                type="button"
                class="btn btn-outline btn-sm"
                phx-click={JS.dispatch("phx:copy")}
                data-copy-value={public_results_url(@poll)}
                aria-live="polite"
              >
                Copy
              </button>
              <.link
                id="view-public-results-link"
                href={~p"/polls/#{@poll.slug}/results"}
                target="_blank"
                rel="noopener noreferrer"
                class="btn btn-outline btn-sm"
              >
                View public page
              </.link>
            </div>
          </div>
          <button
            :if={@publish_results? && @poll.result_visibility == :credentialed}
            id="make-results-public-button"
            type="button"
            phx-click="make-results-public"
            data-confirm="Make these results public? Anyone with the URL will be able to view the aggregate results, which may reveal information in a small electorate."
            class="btn btn-coral"
          >
            Allow public access
          </button>
          <button
            :if={@publish_results? && @poll.result_visibility == :public}
            id="make-results-credentialed-button"
            type="button"
            phx-click="make-results-credentialed"
            data-confirm="Withdraw public access? Voting-link holders will still be able to view published results. Copies already viewed or saved cannot be recalled."
            class="btn btn-outline"
          >
            Require voting links
          </button>
        </div>

        <p :if={@poll.status == :draft} id="results-export-unavailable" class="poll-meta">
          Open the poll before exporting results.
        </p>

        <div
          :if={@confirming_export?}
          id="results-export-confirmation-overlay"
          class="invitation-confirmation-overlay"
          phx-window-keydown="cancel-export"
          phx-key="escape"
        >
          <section
            id="results-export-confirmation"
            class="card card-pad invitation-confirmation"
            role="dialog"
            aria-modal="true"
            aria-labelledby="results-export-confirmation-title"
          >
            <div class="m-eyebrow">CSV results export</div>
            <h2 id="results-export-confirmation-title" class="admin-h2">
              Confirm results download
            </h2>
            <p class="admin-sub">
              Download the {result_state_label(@poll)} aggregate results for <strong>{@poll.title}</strong>.
            </p>
            <dl class="invitation-confirmation-counts">
              <div>
                <dt>Ballots</dt>
                <dd>{@result.ballot_count}</dd>
              </div>
              <div>
                <dt>Turnout</dt>
                <dd>{format_percentage(@result.turnout_percentage)}</dd>
              </div>
              <div>
                <dt>Eligible</dt>
                <dd>{@result.eligible_count}</dd>
              </div>
              <div>
                <dt>Options</dt>
                <dd>{length(@result.options)}</dd>
              </div>
            </dl>
            <div class="callout amber invitation-private-warning">
              <.icon name="hero-exclamation-triangle" class="size-5" />
              <span>
                Aggregate results may still be sensitive for a small electorate. The file contains
                no member identities, ballots, private links, or access tokens.
              </span>
            </div>
            <div class="invitation-confirmation-actions">
              <button
                id="cancel-results-export"
                type="button"
                phx-click="cancel-export"
                class="btn btn-outline"
              >
                Cancel
              </button>
              <.link
                id="download-results-export"
                href={~p"/admin/polls/#{@poll.id}/results.csv"}
                download
                class="btn btn-coral"
              >
                {download_label(@poll)}
              </.link>
            </div>
          </section>
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
          <div :if={@poll.status != :draft} class="card card-pad metric-card">
            <span>{duration_label(@poll)}</span>
            <strong id="poll-duration">{poll_duration(@poll)}</strong>
          </div>
          <div :if={@result.selection_mode == :multiple} class="card card-pad metric-card">
            <span>Total selections</span>
            <strong id="total-selections">{@result.total_selections}</strong>
          </div>
        </div>

        <div class="card card-pad">
          <div class="results-heading">
            <h3>Results</h3>
            <span :if={@winner_summary} id="winner-summary" class="poll-meta">
              {@winner_summary}
            </span>
          </div>
          <p id="results-percentage-explanation" class="poll-meta">
            {percentage_explanation(@result.selection_mode)}
          </p>
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
                  {result_value(row, @result.selection_mode)}
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

  def handle_event("make-results-public", _params, socket),
    do: transition(socket, :make_results_public, "Public results enabled")

  def handle_event("make-results-credentialed", _params, socket),
    do: transition(socket, :make_results_credentialed, "Public results withdrawn")

  def handle_event("prepare-export", _params, socket) do
    if socket.assigns.poll.status != :draft && socket.assigns.result.options != [] do
      {:noreply, assign(socket, :confirming_export?, true)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("cancel-export", _params, socket) do
    {:noreply, assign(socket, :confirming_export?, false)}
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

  defp winner_summary(%{selection_mode: :multiple, winner_labels: [option]}),
    do: "Most selected: #{option}"

  defp winner_summary(%{selection_mode: :multiple, winner_labels: options}),
    do: "Most selected (tie): #{Enum.join(options, " · ")}"

  defp winner_summary(%{winner_labels: [winner]}), do: "Leading: #{winner}"
  defp winner_summary(%{winner_labels: winners}), do: "Tie: #{Enum.join(winners, " · ")}"

  defp percentage_explanation(:multiple),
    do:
      "Percentages show the share of submitted ballots that selected each option and may total more than 100%."

  defp percentage_explanation(:single),
    do: "Percentages show each option's share of submitted ballots."

  defp result_value(row, :multiple) do
    selection_label = if row.votes == 1, do: "selection", else: "selections"
    "#{row.votes} #{selection_label} · selected by #{format_percentage(row.percentage)}"
  end

  defp result_value(row, :single), do: "#{row.votes} · #{format_percentage(row.percentage)}"

  defp lifecycle_copy(%Poll{status: :draft}),
    do: "Opening freezes options and electorate and makes private voting links live."

  defp lifecycle_copy(%Poll{status: :open}),
    do: "Voting is live. Closing is final and immediately stops new submissions."

  defp lifecycle_copy(%Poll{results_published_at: published_at}) when not is_nil(published_at),
    do: "Final results are visible to members with valid access links."

  defp lifecycle_copy(%Poll{status: :closed}),
    do: "Voting is closed. Review the final totals before publishing them to members."

  defp visibility_copy(%Poll{result_visibility: :public, results_published_at: nil}),
    do: "Anyone with the public URL will be able to view aggregate results after publication."

  defp visibility_copy(%Poll{result_visibility: :public}),
    do: "Anyone with the public URL can view these published aggregate results."

  defp visibility_copy(%Poll{results_published_at: nil}),
    do: "Published results will require a member's private voting link."

  defp visibility_copy(%Poll{}),
    do: "Published results require a member's private voting link."

  defp public_results_available?(poll),
    do: poll.result_visibility == :public and not is_nil(poll.results_published_at)

  defp public_results_url(poll),
    do: PollyWeb.Endpoint.url() <> "/polls/#{poll.slug}/results"

  defp duration_label(%Poll{status: :open}), do: "Running time"
  defp duration_label(%Poll{}), do: "Poll duration"

  defp poll_duration(%Poll{status: :open, opened_at: opened_at}),
    do: PollyWeb.PollTiming.duration(opened_at, DateTime.utc_now())

  defp poll_duration(%Poll{opened_at: opened_at, closed_at: closed_at}),
    do: PollyWeb.PollTiming.duration(opened_at, closed_at)

  defp format_percentage(value), do: :erlang.float_to_binary(value, decimals: 1) <> "%"

  defp result_state_label(%Poll{status: :open}), do: "provisional"
  defp result_state_label(%Poll{results_published_at: nil}), do: "final, unpublished"
  defp result_state_label(%Poll{}), do: "final, published"

  defp download_label(%Poll{status: :open}), do: "Download provisional results"
  defp download_label(%Poll{}), do: "Download final results"
end
