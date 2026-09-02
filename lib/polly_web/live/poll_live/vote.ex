defmodule PollyWeb.PollLive.Vote do
  @moduledoc """
  Implements the credential-authenticated public voting experience.

  It resolves the poll-scoped access credential, presents mode-aware selection
  and review states, submits one final ballot atomically, and displays published
  results when the poll permits it.
  """

  use PollyWeb, :live_view

  require Ash.Query

  alias Polly.Polls.{AccessGrant, Ballot, Ballots, Events, SelectionRules}
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
     |> assign(:selected_option_ids, [])
     |> assign(:selected_options, [])
     |> assign(:selection_input_valid?, true)
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
                {@poll.description || "Make your selection below."}
                <br />One vote per member—you won't be
                able to change it after you submit.
              </p>
              <p id="selection-instructions" class="vote-selection-instructions">
                {SelectionRules.summary(@poll)}.
              </p>

              <.form for={@form} id="ballot-form" phx-change="select-option" phx-submit="review">
                <fieldset class="vote-options">
                  <legend class="sr-only">{SelectionRules.summary(@poll)}</legend>
                  <label
                    :for={option <- @options}
                    id={"option-card-#{option.id}"}
                    class={[
                      "touch-option",
                      option.id in @selected_option_ids && "picked",
                      option_disabled?(@poll, @selected_option_ids, option.id) && "disabled"
                    ]}
                  >
                    <input
                      id={"ballot-option-#{option.id}"}
                      type={if(@poll.selection_mode == :single, do: "radio", else: "checkbox")}
                      name={option_input_name(@form, @poll)}
                      value={option.id}
                      checked={option.id in @selected_option_ids}
                      disabled={option_disabled?(@poll, @selected_option_ids, option.id)}
                    />
                    <span class="box" aria-hidden="true">
                      {if(option.id in @selected_option_ids, do: "✓", else: "")}
                    </span>
                    <span class="opt-text">{option.label}</span>
                  </label>
                </fieldset>

                <p
                  :if={@poll.selection_mode == :multiple}
                  id="selection-count"
                  class="vote-selection-count"
                  aria-live="polite"
                >
                  {selection_count_message(@poll, @selected_option_ids)}
                </p>

                <button
                  id="review-ballot-button"
                  type="submit"
                  class="m-submit"
                  disabled={
                    !@selection_input_valid? ||
                      !valid_selection_count?(@poll, @selected_option_ids)
                  }
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
                <div class="review-label">
                  {if(length(@selected_options) == 1, do: "Your selection", else: "Your selections")}
                </div>
                <div id="reviewed-options">
                  <div
                    :for={option <- @selected_options}
                    id={"reviewed-option-#{option.id}"}
                    class="review-value"
                  >
                    {option.label}
                  </div>
                </div>
              </div>
              <p :if={@submission_error} id="submission-error" class="vote-error">
                We couldn't record your ballot. Please try again.
              </p>
              <.form for={@form} id="confirm-ballot-form" phx-submit="submit-ballot">
                <input
                  :for={option_id <- @selected_option_ids}
                  type="hidden"
                  name={option_input_name(@form, @poll)}
                  value={option_id}
                />
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
                Your ballot for <b>{@poll.title}</b>
                is final. Results will be visible here after the poll
                closes and the administrator publishes them.
              </p>
              <div class="receipt">
                <div><span>Poll</span><span>{@poll.title}</span></div>
                <div><span>Voted as</span><span>{@member.name}</span></div>
                <div><span>Submitted</span><span>{format_datetime(@ballot.submitted_at)}</span></div>
                <div :for={option <- @selected_options} id={"receipt-selection-#{option.id}"}>
                  <span>Selection</span><span>{option.label}</span>
                </div>
              </div>
            </div>

            <div :if={@state == :closed} id="poll-closed" class="waiting">
              <div class="ring" aria-hidden="true"></div>
              <h1>RESULTS NOT YET AVAILABLE</h1>
              <p>
                Voting for <b>{@poll.title}</b>
                has closed. Results aren't published yet—check back soon.
              </p>
            </div>

            <div :if={@state == :published} id="published-results">
              <div class="m-eyebrow published-results-eyebrow">
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
  def handle_event("select-option", event_params, socket) do
    params = Map.get(event_params, "ballot", %{})
    {:noreply, assign_selections(socket, selected_ids_from_params(params, socket.assigns.poll))}
  end

  def handle_event("review", event_params, socket) do
    params = Map.get(event_params, "ballot", %{})
    socket = assign_selections(socket, selected_ids_from_params(params, socket.assigns.poll))

    if socket.assigns.selection_input_valid? and
         valid_selection_count?(socket.assigns.poll, socket.assigns.selected_option_ids) do
      {:noreply, assign(socket, :state, :review)}
    else
      {:noreply, put_flash(socket, :error, selection_error_message(socket.assigns.poll))}
    end
  end

  def handle_event("change", _params, socket) do
    {:noreply, assign(socket, :state, :voting)}
  end

  def handle_event("submit-ballot", event_params, socket) do
    params = Map.get(event_params, "ballot", %{})
    socket = assign_selections(socket, selected_ids_from_params(params, socket.assigns.poll))

    if socket.assigns.selection_input_valid? and
         valid_selection_count?(socket.assigns.poll, socket.assigns.selected_option_ids) do
      submit(socket)
    else
      {:noreply,
       socket
       |> assign(:state, :voting)
       |> put_flash(:error, selection_error_message(socket.assigns.poll))}
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

  defp submit(socket) do
    case Ballots.submit(
           socket.assigns.poll.id,
           socket.assigns.token,
           socket.assigns.selected_option_ids
         ) do
      {:ok, ballot} ->
        {:noreply,
         socket
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

    selected_options =
      ballot.selections
      |> Enum.map(& &1.option)
      |> Enum.sort_by(& &1.position)

    socket
    |> assign(:ballot, ballot)
    |> assign(:selected_options, selected_options)
    |> assign(:selected_option_ids, Enum.map(selected_options, & &1.id))
    |> assign(:selection_input_valid?, true)
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

  defp assign_selections(socket, option_ids) do
    selected_options = Enum.filter(socket.assigns.options, &(&1.id in option_ids))
    selected_ids = Enum.map(selected_options, & &1.id)

    socket
    |> assign(:selected_option_ids, selected_ids)
    |> assign(:selected_options, selected_options)
    |> assign(
      :selection_input_valid?,
      length(option_ids) == length(selected_ids) and
        MapSet.new(option_ids) == MapSet.new(selected_ids)
    )
    |> assign_form()
  end

  defp assign_form(socket) do
    assign(
      socket,
      :form,
      to_form(
        %{
          "option_id" => List.first(socket.assigns.selected_option_ids),
          "option_ids" => socket.assigns.selected_option_ids
        },
        as: :ballot
      )
    )
  end

  defp selected_ids_from_params(params, %{selection_mode: :single}) do
    case Map.get(params, "option_id") do
      option_id when is_binary(option_id) -> [option_id]
      _other -> []
    end
  end

  defp selected_ids_from_params(params, %{selection_mode: :multiple}) do
    case Map.get(params, "option_ids", []) do
      option_ids when is_list(option_ids) -> option_ids
      option_id when is_binary(option_id) -> [option_id]
      _other -> []
    end
  end

  defp option_input_name(form, %{selection_mode: :single}), do: form[:option_id].name
  defp option_input_name(_form, %{selection_mode: :multiple}), do: "ballot[option_ids][]"

  defp valid_selection_count?(poll, option_ids) do
    count = length(option_ids)
    count >= poll.minimum_selections and count <= poll.maximum_selections
  end

  defp option_disabled?(%{selection_mode: :single}, _selected_ids, _option_id), do: false

  defp option_disabled?(poll, selected_ids, option_id) do
    length(selected_ids) >= poll.maximum_selections and option_id not in selected_ids
  end

  defp selection_count_message(poll, option_ids) do
    count = length(option_ids)

    if poll.minimum_selections == poll.maximum_selections do
      "#{count} of #{poll.maximum_selections} selected"
    else
      "#{count} selected · choose #{poll.minimum_selections}–#{poll.maximum_selections}"
    end
  end

  defp selection_error_message(%{minimum_selections: minimum, maximum_selections: maximum})
       when minimum == maximum,
       do: "Choose exactly #{minimum} options before continuing"

  defp selection_error_message(%{minimum_selections: minimum, maximum_selections: maximum}),
    do: "Choose between #{minimum} and #{maximum} options before continuing"

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
