defmodule PollyWeb.PollLive.Vote do
  use PollyWeb, :live_view

  require Ash.Query

  alias Polly.Polls.{AccessGrant, Ballot, Ballots, Events}
  alias Polly.Polls.Results, as: PollResults

  @impl true
  def mount(%{"poll_id" => poll_id, "token" => token}, _session, socket) do
    if connected?(socket), do: Events.subscribe(poll_id)

    {:ok,
     socket
     |> stream_configure(:published_results, dom_id: &"published-result-#{&1.option.id}")
     |> assign(:page_title, "Vote")
     |> assign(:poll_id, poll_id)
     |> assign(:token, token)
     |> assign(:selected_option_id, nil)
     |> assign(:selected_option, nil)
     |> assign(:ballot, nil)
     |> assign(:submission_error, nil)
     |> load_access()}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <section id="public-vote-page" class="member-wrap public-vote-page">
        <div class="phone vote-card">
          <div class="phone-notch" aria-hidden="true"></div>
          <div class="phone-screen">
            <div :if={@state == :invalid} id="invalid-voting-link" class="m-confirm denied-state">
              <div class="stamp denied"><.icon name="hero-link-slash" class="size-8" /></div>
              <h1>LINK NOT AVAILABLE</h1>
              <p>
                This private voting link is invalid, expired, or has been revoked. Ask the poll
                administrator for a current link.
              </p>
            </div>

            <div :if={@state == :draft} id="poll-not-open" class="waiting">
              <div class="ring paused" aria-hidden="true"></div>
              <div class="m-eyebrow">Voting has not started</div>
              <h1 class="m-title state-title">{@poll.title}</h1>
              <p class="state-copy">
                This poll is still being prepared. Return to this private link after voting opens.
              </p>
            </div>

            <div :if={@state == :voting} id="open-ballot">
              <div class="m-eyebrow">
                <span class="vote-live-dot" aria-hidden="true">●</span> Voting open
              </div>
              <h1 class="m-title">{@poll.title}</h1>
              <p class="m-desc">
                {@poll.description || "Choose one option below."} One vote per member—you won't be
                able to change it after you submit.
              </p>

              <.form for={@form} id="ballot-form" phx-change="select-option" phx-submit="review">
                <fieldset class="vote-options">
                  <legend class="sr-only">Choose one option</legend>
                  <label
                    :for={option <- @options}
                    id={"option-card-#{option.id}"}
                    class={[
                      "touch-option",
                      @selected_option_id == option.id && "picked"
                    ]}
                  >
                    <input
                      id={"ballot-option-#{option.id}"}
                      type="radio"
                      name={@form[:option_id].name}
                      value={option.id}
                      checked={@selected_option_id == option.id}
                    />
                    <span class="box" aria-hidden="true">
                      {if(@selected_option_id == option.id, do: "✓", else: "")}
                    </span>
                    <span class="opt-text">{option.label}</span>
                  </label>
                </fieldset>

                <button
                  id="review-ballot-button"
                  type="submit"
                  class="m-submit"
                  disabled={is_nil(@selected_option_id)}
                >
                  Review my vote
                </button>
              </.form>
              <p class="m-fine">
                This private link identifies {@member.name}. One final ballot may be submitted.
              </p>
            </div>

            <div :if={@state == :review} id="ballot-review">
              <div class="m-eyebrow">Step 2 of 2 · Confirm</div>
              <h1 class="m-title review-title">Review before you submit</h1>
              <p class="m-desc">
                Once you confirm, this ballot is final. There's no edit or resubmit.
              </p>
              <div class="review-card">
                <div class="review-label">Your selection</div>
                <div id="reviewed-option" class="review-value">{@selected_option.label}</div>
              </div>
              <p :if={@submission_error} id="submission-error" class="vote-error">
                We couldn't record your ballot. Please try again.
              </p>
              <.form for={@form} id="confirm-ballot-form" phx-submit="submit-ballot">
                <input type="hidden" name={@form[:option_id].name} value={@selected_option_id} />
                <button id="confirm-ballot-button" type="submit" class="m-submit">
                  Confirm and submit
                </button>
              </.form>
              <button id="change-ballot-button" type="button" phx-click="change" class="m-back">
                Go back and change my answer
              </button>
            </div>

            <div
              :if={@state in [:submitted, :already_submitted]}
              id={if(@state == :submitted, do: "ballot-submitted", else: "ballot-already-submitted")}
              class="m-confirm"
            >
              <div class="stamp"><.icon name="hero-check" class="size-8" /></div>
              <h1>VOTE RECORDED</h1>
              <p>
                Your ballot for {@poll.title} is final. Results will be visible here after the poll
                closes and the administrator publishes them.
              </p>
              <div class="receipt">
                <div><span>Poll</span><span>{@poll.title}</span></div>
                <div><span>Voted as</span><span>{@member.name}</span></div>
                <div><span>Submitted</span><span>{format_datetime(@ballot.submitted_at)}</span></div>
                <div :if={@selected_option}>
                  <span>Selection</span><span>{@selected_option.label}</span>
                </div>
              </div>
            </div>

            <div :if={@state == :closed} id="poll-closed" class="waiting">
              <div class="ring" aria-hidden="true"></div>
              <h1>RESULTS NOT YET AVAILABLE</h1>
              <p>
                Voting for {@poll.title} has closed. Results aren't published yet—check back soon.
              </p>
            </div>

            <div :if={@state == :published} id="published-results">
              <div class="m-eyebrow">
                Results published · {format_date(@poll.results_published_at)}
              </div>
              <div class="m-results-hero">
                <div class="k">{@poll.title}</div>
                <div id="published-winner" class="v">{@winner_summary}</div>
                <div class="laneline results-laneline"></div>
                <div class="published-turnout">
                  {@result.ballot_count} of {@result.eligible_count} members voted · {format_percentage(
                    @result.turnout_percentage
                  )} turnout
                </div>
              </div>

              <div id="member-results" phx-update="stream">
                <div id="member-results-empty" class="empty-state hidden only:block">
                  <h2>No results available</h2>
                </div>
                <div
                  :for={{id, row} <- @streams.published_results}
                  id={id}
                  class={["m-result-row", row.winner? && "win"]}
                >
                  <div class="m-result-top">
                    <b>{row.option.label}</b>
                    <span>{row.votes} · {format_percentage(row.percentage)}</span>
                  </div>
                  <div class="m-result-track">
                    <div class="m-result-fill" style={"width: #{row.percentage}%"}></div>
                  </div>
                </div>
              </div>
            </div>
          </div>
        </div>
      </section>
    </Layouts.app>
    """
  end

  @impl true
  def handle_event("select-option", %{"ballot" => %{"option_id" => option_id}}, socket) do
    case option_for_id(socket.assigns.options, option_id) do
      nil -> {:noreply, socket}
      option -> {:noreply, assign_selection(socket, option)}
    end
  end

  def handle_event("review", %{"ballot" => %{"option_id" => option_id}}, socket) do
    case option_for_id(socket.assigns.options, option_id) do
      nil -> {:noreply, put_flash(socket, :error, "Choose an option before continuing")}
      option -> {:noreply, socket |> assign_selection(option) |> assign(:state, :review)}
    end
  end

  def handle_event("change", _params, socket) do
    {:noreply, assign(socket, :state, :voting)}
  end

  def handle_event("submit-ballot", %{"ballot" => %{"option_id" => option_id}}, socket) do
    case option_for_id(socket.assigns.options, option_id) do
      nil ->
        {:noreply, socket |> assign(:state, :voting) |> put_flash(:error, "Choose an option")}

      option ->
        submit(socket, option)
    end
  end

  @impl true
  def handle_info({:poll_status_changed, poll_id, _status, _published_at}, socket)
      when poll_id == socket.assigns.poll_id do
    {:noreply, load_access(socket)}
  end

  def handle_info({:poll_results_changed, poll_id}, %{assigns: %{state: :published}} = socket)
      when poll_id == socket.assigns.poll_id do
    {:noreply, load_access(socket)}
  end

  def handle_info({:poll_results_changed, _poll_id}, socket), do: {:noreply, socket}

  defp submit(socket, option) do
    case Ballots.submit(socket.assigns.poll.id, socket.assigns.token, option.id) do
      {:ok, ballot} ->
        {:noreply,
         socket
         |> assign_selection(option)
         |> assign(:ballot, ballot)
         |> assign(:state, :submitted)}

      {:error, :already_submitted} ->
        {:noreply, load_access(socket)}

      {:error, :invalid_grant} ->
        {:noreply, assign(socket, :state, :invalid)}

      {:error, :poll_not_open} ->
        {:noreply, load_access(socket)}

      {:error, _reason} ->
        {:noreply, assign(socket, :submission_error, true)}
    end
  end

  defp load_access(socket) do
    with {:ok, grant} <- AccessGrant.resolve(socket.assigns.poll_id, socket.assigns.token) do
      grant = Ash.load!(grant, [:member, poll: [:options]], authorize?: false)
      ballot = existing_ballot(grant.poll_id, grant.member_id)

      socket
      |> assign(:grant, grant)
      |> assign(:member, grant.member)
      |> assign(:poll, grant.poll)
      |> assign(:options, Enum.filter(grant.poll.options, & &1.active))
      |> assign(:page_title, grant.poll.title)
      |> assign_ballot_state(ballot)
    else
      {:error, _error} -> assign(socket, :state, :invalid)
    end
  end

  defp assign_ballot_state(socket, ballot) do
    case socket.assigns.poll.status do
      :draft ->
        assign(socket, :state, :draft)

      :closed when not is_nil(socket.assigns.poll.results_published_at) ->
        assign_published_results(socket)

      :closed ->
        socket |> assign(:ballot, ballot) |> assign(:state, :closed)

      :open when not is_nil(ballot) ->
        assign_existing_ballot(socket, ballot)

      :open ->
        socket |> assign(:state, :voting) |> assign_form()
    end
  end

  defp assign_existing_ballot(socket, ballot) do
    ballot = Ash.load!(ballot, [selections: [:option]], authorize?: false)
    selection = List.first(ballot.selections)

    socket
    |> assign(:ballot, ballot)
    |> assign(:selected_option, selection && selection.option)
    |> assign(:selected_option_id, selection && selection.option_id)
    |> assign(:state, :already_submitted)
  end

  defp assign_published_results(socket) do
    result = PollResults.for_poll(socket.assigns.poll)

    socket
    |> assign(:result, result)
    |> assign(:winner_summary, published_winner_summary(result))
    |> assign(:state, :published)
    |> stream(:published_results, result.options, reset: true)
  end

  defp existing_ballot(poll_id, member_id) do
    Ballot
    |> Ash.Query.filter(poll_id == ^poll_id and member_id == ^member_id)
    |> Ash.read_one!(authorize?: false)
  end

  defp assign_selection(socket, option) do
    socket
    |> assign(:selected_option_id, option.id)
    |> assign(:selected_option, option)
    |> assign_form()
  end

  defp assign_form(socket) do
    assign(
      socket,
      :form,
      to_form(%{"option_id" => socket.assigns.selected_option_id}, as: :ballot)
    )
  end

  defp option_for_id(options, option_id), do: Enum.find(options, &(&1.id == option_id))

  defp format_datetime(datetime) do
    Calendar.strftime(datetime, "%b %-d, %Y %-I:%M %p UTC")
  end

  defp format_date(datetime), do: Calendar.strftime(datetime, "%b %-d, %Y")
  defp format_percentage(value), do: :erlang.float_to_binary(value, decimals: 1) <> "%"

  defp published_winner_summary(%{ballot_count: 0}), do: "No ballots submitted"
  defp published_winner_summary(%{winner_labels: [winner]}), do: winner

  defp published_winner_summary(%{winner_labels: winners}),
    do: "Tie: #{Enum.join(winners, " · ")}"
end
