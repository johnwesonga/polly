defmodule PollyWeb.PollLive.Lifecycle do
  @moduledoc """
  Presents manual and scheduled lifecycle controls for an administrator poll.

  The page keeps opening and closing separate from result publication and
  exposes UTC scheduling, replacement, cancellation, and transition history.
  """

  use PollyWeb, :live_view

  alias Polly.Accounts.Authorization
  alias Polly.Polls.{Events, LifecycleScheduling, LifecycleTransition, Poll, Readiness}

  on_mount {PollyWeb.LiveUserAuth, {:require_any_permission, [:manage_polls, :publish_results]}}

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    actor = socket.assigns.current_user
    poll = Ash.get!(Poll, id, actor: actor)

    if connected?(socket), do: Events.subscribe(poll.id)

    {:ok,
     socket
     |> assign(:page_title, "#{poll.title} lifecycle")
     |> assign(:poll, poll)
     |> assign(:manage_polls?, Authorization.allowed?(actor, :manage_polls))
     |> assign(:publish_results?, Authorization.allowed?(actor, :publish_results))
     |> assign(:pending_action, nil)
     |> assign_forms()
     |> load_lifecycle()}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} active_nav={:polls}>
      <section id="poll-lifecycle-page">
        <div class="breadcrumb">
          <.link navigate={~p"/admin/polls"}>Polls</.link><span>/</span><span>{@poll.title}</span>
        </div>

        <div class="detail-header">
          <div>
            <div class="admin-h2">{String.upcase(@poll.title)}</div>
            <p class="admin-sub" style="margin:4px 0 0;">
              Open voting now or schedule lifecycle changes in UTC.
            </p>
          </div>
          <div class="flex flex-wrap items-center justify-end gap-2">
            <.privacy_badge id="poll-lifecycle-privacy" privacy_mode={@poll.privacy_mode} />
            <span id="poll-lifecycle-status" class={"pill #{@poll.status}"}>{@poll.status}</span>
          </div>
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
          <span class="phase-tab current">Lifecycle</span>
          <.link navigate={~p"/admin/polls/#{@poll.id}/results"} class="phase-tab">
            Results
          </.link>
        </div>

        <div :if={@poll.status == :draft} id="poll-readiness" class="card card-pad">
          <div class="lifecycle-section-heading">
            <div>
              <div class="admin-h3">Opening readiness</div>
              <p class="admin-sub">Readiness is checked again when scheduled opening runs.</p>
            </div>
            <span class={if(@ready?, do: "pill open", else: "pill draft")}>
              {if(@ready?, do: "Ready", else: "Needs attention")}
            </span>
          </div>
          <ul class="lifecycle-checklist">
            <li id="readiness-options" class={if(@options_ready?, do: "done", else: nil)}>
              <.icon
                name={if(@options_ready?, do: "hero-check-circle", else: "hero-minus-circle")}
                class="size-5"
              />
              {@option_count} active options; at least two required
            </li>
            <li id="readiness-electorate" class={if(@electorate_ready?, do: "done", else: nil)}>
              <.icon
                name={if(@electorate_ready?, do: "hero-check-circle", else: "hero-minus-circle")}
                class="size-5"
              />
              {if(@electorate_ready?, do: "Electorate configured", else: "No eligible members")}
            </li>
            <li id="readiness-selection-limits" class={if(@limits_ready?, do: "done", else: nil)}>
              <.icon
                name={if(@limits_ready?, do: "hero-check-circle", else: "hero-minus-circle")}
                class="size-5"
              /> Selection limits fit the active options
            </li>
          </ul>
        </div>

        <div id="lifecycle-actions" class="lifecycle-grid">
          <section class="card card-pad">
            <div class="admin-h3">Manual lifecycle</div>
            <p class="admin-sub">Apply the next lifecycle change immediately.</p>

            <button
              :if={@manage_polls? && @poll.status == :draft}
              id="open-poll-now-button"
              type="button"
              phx-click="prepare-manual"
              phx-value-kind="open"
              class="btn btn-coral"
            >
              Open poll now
            </button>
            <button
              :if={@publish_results? && @poll.status == :open}
              id="close-poll-now-button"
              type="button"
              phx-click="prepare-manual"
              phx-value-kind="close"
              class="btn btn-coral"
            >
              Close poll now
            </button>
            <p :if={@poll.status == :closed} id="closed-lifecycle-message" class="poll-meta">
              This poll is closed. Lifecycle changes are final.
            </p>
          </section>

          <section :if={@poll.status != :closed} class="card card-pad">
            <div class="admin-h3">Schedule a transition</div>
            <p class="admin-sub">Times are entered and displayed in UTC.</p>

            <.form
              :if={@manage_polls? && @poll.status == :draft && is_nil(@pending_open)}
              for={@open_form}
              id="schedule-open-form"
              phx-submit="prepare-schedule"
              class="lifecycle-form"
            >
              <input type="hidden" name="kind" value="open" />
              <.input
                field={@open_form[:scheduled_at]}
                id="schedule-open-at"
                type="datetime-local"
                label="Open at (UTC)"
                required
              />
              <button id="schedule-open-button" type="submit" class="btn btn-outline btn-sm">
                Schedule opening
              </button>
            </.form>

            <.form
              :if={@publish_results? && is_nil(@pending_close)}
              for={@close_form}
              id="schedule-close-form"
              phx-submit="prepare-schedule"
              class="lifecycle-form"
            >
              <input type="hidden" name="kind" value="close" />
              <.input
                field={@close_form[:scheduled_at]}
                id="schedule-close-at"
                type="datetime-local"
                label="Close at (UTC)"
                required
              />
              <button id="schedule-close-button" type="submit" class="btn btn-outline btn-sm">
                Schedule closing
              </button>
            </.form>

            <p
              :if={
                is_nil(@pending_open) && is_nil(@pending_close) && !@manage_polls? &&
                  !@publish_results?
              }
              class="poll-meta"
            >
              You do not have permission to configure lifecycle transitions.
            </p>
          </section>
        </div>

        <section id="pending-transitions" class="card card-pad lifecycle-history-card">
          <div class="admin-h3">Pending transitions</div>
          <p class="admin-sub">Scheduled jobs use UTC and execute on a best-effort basis.</p>

          <div :if={@pending_transitions == []} id="pending-transitions-empty" class="empty-state">
            <p>No lifecycle changes are scheduled.</p>
          </div>

          <div
            :for={transition <- @pending_transitions}
            id={"pending-transition-#{transition.id}"}
            class="lifecycle-transition-row"
          >
            <div>
              <strong>{transition_label(transition.kind)}</strong>
              <div class="poll-meta">{format_utc(transition.scheduled_at)}</div>
            </div>
            <div class="lifecycle-transition-actions">
              <.form
                :if={can_manage_transition?(assigns, transition)}
                for={replacement_form(transition)}
                id={"replace-transition-form-#{transition.id}"}
                phx-submit="prepare-replace"
                class="lifecycle-replacement-form"
              >
                <input type="hidden" name="transition_id" value={transition.id} />
                <.input
                  field={replacement_form(transition)[:scheduled_at]}
                  id={"replace-transition-at-#{transition.id}"}
                  type="datetime-local"
                  label="New UTC time"
                  required
                />
                <button type="submit" class="btn btn-outline btn-sm">Reschedule</button>
              </.form>
              <button
                :if={can_manage_transition?(assigns, transition)}
                id={"cancel-transition-#{transition.id}"}
                type="button"
                phx-click="prepare-cancel"
                phx-value-id={transition.id}
                class="btn btn-ghost btn-sm"
              >
                Cancel
              </button>
            </div>
          </div>
        </section>

        <section id="transition-history" class="card card-pad lifecycle-history-card">
          <div class="admin-h3">Lifecycle history</div>
          <div :if={@history == []} id="transition-history-empty" class="empty-state">
            <p>No completed lifecycle history yet.</p>
          </div>
          <div
            :for={transition <- @history}
            id={"transition-history-#{transition.id}"}
            class="lifecycle-transition-row"
          >
            <div>
              <strong>{transition_label(transition.kind)}</strong>
              <div class="poll-meta">Scheduled for {format_utc(transition.scheduled_at)}</div>
            </div>
            <div class="lifecycle-history-outcome">
              <span class={"pill #{transition_state_class(transition.state)}"}>
                {transition.state}
              </span>
              <span :if={transition.failure_code} class="poll-meta">
                {failure_message(transition.failure_code)}
              </span>
            </div>
          </div>
        </section>

        <div
          :if={@pending_action}
          id="lifecycle-confirmation-overlay"
          class="invitation-confirmation-overlay"
          phx-window-keydown="cancel-confirmation"
          phx-key="escape"
        >
          <section
            id="lifecycle-confirmation"
            class="card card-pad invitation-confirmation"
            role="dialog"
            aria-modal="true"
            aria-labelledby="lifecycle-confirmation-title"
          >
            <div class="m-eyebrow">Confirm lifecycle change</div>
            <h2 id="lifecycle-confirmation-title" class="admin-h2">
              {confirmation_title(@pending_action)}
            </h2>
            <p class="admin-sub">{confirmation_message(@pending_action, @poll)}</p>
            <div class="invitation-confirmation-actions">
              <button
                id="cancel-lifecycle-confirmation"
                type="button"
                phx-click="cancel-confirmation"
                class="btn btn-outline"
              >
                Keep current lifecycle
              </button>
              <button
                id="confirm-lifecycle-action"
                type="button"
                phx-click="confirm-action"
                class="btn btn-coral"
              >
                Confirm
              </button>
            </div>
          </section>
        </div>
      </section>
    </Layouts.app>
    """
  end

  @impl true
  def handle_event("prepare-schedule", %{"kind" => kind} = params, socket) do
    with {:ok, kind} <- parse_kind(kind),
         {:ok, scheduled_at} <- parse_datetime(schedule_params(params)["scheduled_at"]) do
      {:noreply, assign(socket, :pending_action, {:schedule, kind, scheduled_at})}
    else
      {:error, message} -> {:noreply, put_flash(socket, :error, message)}
    end
  end

  def handle_event(
        "prepare-replace",
        %{"transition_id" => id, "replacement" => %{"scheduled_at" => value}},
        socket
      ) do
    with %LifecycleTransition{} = transition <- find_pending(socket, id),
         true <- can_manage_transition?(socket.assigns, transition),
         {:ok, scheduled_at} <- parse_datetime(value) do
      {:noreply, assign(socket, :pending_action, {:replace, transition, scheduled_at})}
    else
      false -> {:noreply, put_flash(socket, :error, "You cannot change this transition")}
      nil -> {:noreply, put_flash(socket, :error, "The transition is no longer pending")}
      {:error, message} -> {:noreply, put_flash(socket, :error, message)}
    end
  end

  def handle_event("prepare-cancel", %{"id" => id}, socket) do
    case find_pending(socket, id) do
      %LifecycleTransition{} = transition ->
        if can_manage_transition?(socket.assigns, transition) do
          {:noreply, assign(socket, :pending_action, {:cancel, transition})}
        else
          {:noreply, put_flash(socket, :error, "You cannot cancel this transition")}
        end

      nil ->
        {:noreply, put_flash(socket, :error, "The transition is no longer pending")}
    end
  end

  def handle_event("prepare-manual", %{"kind" => kind}, socket) do
    with {:ok, kind} <- parse_kind(kind),
         true <- can_manage_kind?(socket.assigns, kind) do
      {:noreply, assign(socket, :pending_action, {:manual, kind})}
    else
      _ -> {:noreply, put_flash(socket, :error, "You cannot perform this lifecycle change")}
    end
  end

  def handle_event("cancel-confirmation", _params, socket) do
    {:noreply, assign(socket, :pending_action, nil)}
  end

  def handle_event("confirm-action", _params, %{assigns: %{pending_action: action}} = socket) do
    execute_action(socket, action)
  end

  def handle_event("confirm-action", _params, socket), do: {:noreply, socket}

  @impl true
  def handle_info(
        {:poll_status_changed, poll_id, _status, _published_at},
        %{assigns: %{poll: %{id: poll_id}}} = socket
      ) do
    {:noreply, reload(socket)}
  end

  defp execute_action(socket, {:schedule, kind, scheduled_at}) do
    case LifecycleScheduling.schedule(
           socket.assigns.poll,
           %{kind: kind, scheduled_at: scheduled_at},
           socket.assigns.current_user
         ) do
      {:ok, _transition} -> success(socket, "#{transition_label(kind)} scheduled")
      {:error, error} -> failure(socket, error)
    end
  end

  defp execute_action(socket, {:replace, transition, scheduled_at}) do
    case LifecycleScheduling.replace(transition, scheduled_at, socket.assigns.current_user) do
      {:ok, _replacement} -> success(socket, "Lifecycle transition rescheduled")
      {:error, error} -> failure(socket, error)
    end
  end

  defp execute_action(socket, {:cancel, transition}) do
    case LifecycleScheduling.cancel(transition, socket.assigns.current_user) do
      {:ok, _cancelled} -> success(socket, "Lifecycle transition cancelled")
      {:error, error} -> failure(socket, error)
    end
  end

  defp execute_action(socket, {:manual, kind}) do
    action = if(kind == :open, do: :open, else: :close)

    case Ash.update(socket.assigns.poll, %{},
           action: action,
           actor: socket.assigns.current_user
         ) do
      {:ok, _poll} -> success(socket, "Poll #{if(kind == :open, do: "opened", else: "closed")}")
      {:error, error} -> failure(socket, error)
    end
  end

  defp success(socket, message) do
    {:noreply,
     socket
     |> assign(:pending_action, nil)
     |> put_flash(:info, message)
     |> reload()}
  end

  defp failure(socket, error) do
    {:noreply,
     socket
     |> assign(:pending_action, nil)
     |> put_flash(:error, error_message(error))
     |> load_lifecycle()}
  end

  defp reload(socket) do
    poll = Ash.get!(Poll, socket.assigns.poll.id, actor: socket.assigns.current_user)
    socket |> assign(:poll, poll) |> assign_forms() |> load_lifecycle()
  end

  defp load_lifecycle(socket) do
    {:ok, transitions} =
      LifecycleScheduling.list_for_poll(socket.assigns.poll, socket.assigns.current_user)

    {pending, history} = Enum.split_with(transitions, &(&1.state == :pending))
    option_count = Readiness.active_option_count(socket.assigns.poll.id)
    electorate_ready? = Readiness.has_eligible_members?(socket.assigns.poll.id)
    options_ready? = option_count >= 2
    limits_ready? = socket.assigns.poll.maximum_selections <= option_count

    socket
    |> assign(:transitions, transitions)
    |> assign(:pending_transitions, pending)
    |> assign(:history, Enum.reverse(history))
    |> assign(:pending_open, Enum.find(pending, &(&1.kind == :open)))
    |> assign(:pending_close, Enum.find(pending, &(&1.kind == :close)))
    |> assign(:option_count, option_count)
    |> assign(:options_ready?, options_ready?)
    |> assign(:electorate_ready?, electorate_ready?)
    |> assign(:limits_ready?, limits_ready?)
    |> assign(:ready?, options_ready? && electorate_ready? && limits_ready?)
  end

  defp assign_forms(socket) do
    socket
    |> assign(:open_form, to_form(%{"scheduled_at" => ""}, as: :schedule_open))
    |> assign(:close_form, to_form(%{"scheduled_at" => ""}, as: :schedule_close))
  end

  defp replacement_form(transition) do
    to_form(
      %{"scheduled_at" => datetime_local_value(transition.scheduled_at)},
      as: :replacement
    )
  end

  defp schedule_params(%{"schedule_open" => params}), do: params
  defp schedule_params(%{"schedule_close" => params}), do: params
  defp schedule_params(_params), do: %{}

  defp parse_kind("open"), do: {:ok, :open}
  defp parse_kind("close"), do: {:ok, :close}
  defp parse_kind(_kind), do: {:error, "Unknown lifecycle transition"}

  defp parse_datetime(value) when is_binary(value) and value != "" do
    value = if String.length(value) == 16, do: value <> ":00", else: value

    case NaiveDateTime.from_iso8601(value) do
      {:ok, datetime} -> {:ok, DateTime.from_naive!(datetime, "Etc/UTC")}
      {:error, _reason} -> {:error, "Enter a valid UTC date and time"}
    end
  end

  defp parse_datetime(_value), do: {:error, "Enter a UTC date and time"}

  defp find_pending(socket, id),
    do: Enum.find(socket.assigns.pending_transitions, &(&1.id == id))

  defp can_manage_transition?(assigns, %{kind: kind}), do: can_manage_kind?(assigns, kind)
  defp can_manage_kind?(assigns, :open), do: assigns.manage_polls?
  defp can_manage_kind?(assigns, :close), do: assigns.publish_results?

  defp transition_label(:open), do: "Opening"
  defp transition_label(:close), do: "Closing"

  defp confirmation_title({:schedule, kind, _datetime}),
    do: "Schedule #{String.downcase(transition_label(kind))}"

  defp confirmation_title({:replace, transition, _datetime}),
    do: "Reschedule #{String.downcase(transition_label(transition.kind))}"

  defp confirmation_title({:cancel, transition}),
    do: "Cancel scheduled #{String.downcase(transition_label(transition.kind))}"

  defp confirmation_title({:manual, :open}), do: "Open poll now"
  defp confirmation_title({:manual, :close}), do: "Close poll now"

  defp confirmation_message({:schedule, kind, datetime}, _poll),
    do: "#{transition_label(kind)} is scheduled for #{format_utc(datetime)}."

  defp confirmation_message({:replace, _transition, datetime}, _poll),
    do: "The previous schedule will be cancelled and replaced with #{format_utc(datetime)}."

  defp confirmation_message({:cancel, transition}, _poll),
    do:
      "The #{String.downcase(transition_label(transition.kind))} scheduled for #{format_utc(transition.scheduled_at)} will be cancelled."

  defp confirmation_message({:manual, :open}, %{privacy_mode: :anonymous}),
    do: "Opening freezes the configuration. Choices will not be associated with members."

  defp confirmation_message({:manual, :open}, _poll),
    do: "Opening freezes options and electorate and makes private voting links live."

  defp confirmation_message({:manual, :close}, _poll),
    do: "Closing is final and immediately stops new ballot submissions."

  defp format_utc(datetime) do
    Calendar.strftime(datetime, "%Y-%m-%d %H:%M UTC")
  end

  defp datetime_local_value(datetime), do: Calendar.strftime(datetime, "%Y-%m-%dT%H:%M")

  defp transition_state_class(:completed), do: "open"
  defp transition_state_class(:failed), do: "closed"
  defp transition_state_class(_state), do: "draft"

  defp failure_message("insufficient_options"), do: "Not enough active options"
  defp failure_message("no_eligible_members"), do: "No eligible members"
  defp failure_message("selection_limits_invalid"), do: "Selection limits do not fit options"
  defp failure_message("selection_rules_invalid"), do: "Selection rules are invalid"
  defp failure_message("poll_not_draft"), do: "Poll was no longer a draft"
  defp failure_message("poll_not_open"), do: "Poll was not open"
  defp failure_message(_code), do: "Transition could not be applied"

  defp error_message(error) when is_atom(error) do
    error
    |> Atom.to_string()
    |> String.replace("_", " ")
    |> String.capitalize()
  end

  defp error_message(error), do: Exception.message(error)
end
