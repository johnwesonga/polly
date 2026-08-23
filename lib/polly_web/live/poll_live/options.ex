defmodule PollyWeb.PollLive.Options do
  use PollyWeb, :live_view

  require Ash.Query

  alias Polly.Polls.{Option, Poll}

  on_mount {PollyWeb.LiveUserAuth, :live_user_required}

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    actor = socket.assigns.current_user
    poll = Ash.get!(Poll, id, actor: actor)
    options = list_options(poll, actor)

    {:ok,
     socket
     |> assign(:page_title, "#{poll.title} options")
     |> assign(:poll, poll)
     |> assign(:option_count, length(options))
     |> assign(:editing_option_id, nil)
     |> assign(:edit_form, nil)
     |> assign_create_form()
     |> stream(:options, options)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} active_nav={:polls}>
      <section id="poll-options-page">
        <div class="breadcrumb">
          <.link navigate={~p"/admin/polls"}>Polls</.link><span>/</span><span>{@poll.title}</span>
        </div>
        <div class="detail-header">
          <div>
            <div class="admin-h1">{String.upcase(@poll.title)}</div>
            <p class="admin-sub" style="margin:4px 0 0;">
              Add and order the choices members will see.
            </p>
          </div>
          <div class="flex items-center gap-2">
            <span class={"pill #{@poll.status}"}>{@poll.status}</span>
            <div>
              <.link
                :if={@poll.status == :draft}
                id="edit-poll-details-link"
                navigate={~p"/admin/polls/#{@poll.id}/edit"}
                class="btn btn-ghost btn-sm"
              >
                Edit details
              </.link>
            </div>
          </div>
        </div>

        <div class="detail-tabs" aria-label="Poll configuration sections">
          <span class="phase-tab current">Options</span>
          <.link navigate={~p"/admin/polls/#{@poll.id}/electorate"} class="phase-tab">
            Electorate
          </.link>
          <.link navigate={~p"/admin/polls/#{@poll.id}/access"} class="phase-tab">Access links</.link>
          <.link navigate={~p"/admin/polls/#{@poll.id}/results"} class="phase-tab">Results</.link>
        </div>

        <div
          :if={@poll.status != :draft}
          id="options-frozen-notice"
          class="callout amber"
        >
          <.icon name="hero-lock-closed" class="size-5" />
          <span>Options are frozen because this poll is no longer a draft.</span>
        </div>

        <div class="detail-grid">
          <div class="card card-pad">
            <div class="flex items-center justify-between" style="margin-bottom:10px;">
              <h3 style="margin:0;">Ballot options</h3>
              <span id="option-count" class="option-count">
                {@option_count} options
              </span>
            </div>

            <div id="poll-options" phx-update="stream">
              <div id="poll-options-empty" class="empty-state hidden only:block">
                <h2>No options yet</h2>
                <p>Add at least two before opening the poll.</p>
              </div>
              <div
                :for={{id, option} <- @streams.options}
                id={id}
                class="option-row"
              >
                <span class="option-pos">
                  {option.position}
                </span>
                <span class="option-label">{option.label}</span>
                <div :if={@poll.status == :draft} class="option-actions">
                  <div class="reorder">
                    <button
                      id={"move-option-up-#{option.id}"}
                      type="button"
                      phx-click="move"
                      phx-value-id={option.id}
                      phx-value-direction="up"
                      disabled={option.position == 1}
                      aria-label={"Move #{option.label} up"}
                    >
                      <.icon name="hero-chevron-up" class="size-3" />
                    </button>
                    <button
                      id={"move-option-down-#{option.id}"}
                      type="button"
                      phx-click="move"
                      phx-value-id={option.id}
                      phx-value-direction="down"
                      disabled={option.position == @option_count}
                      aria-label={"Move #{option.label} down"}
                    >
                      <.icon name="hero-chevron-down" class="size-3" />
                    </button>
                  </div>
                  <button
                    id={"edit-option-#{option.id}"}
                    type="button"
                    phx-click="edit"
                    phx-value-id={option.id}
                    class="icon-btn"
                    aria-label={"Edit #{option.label}"}
                  >
                    <.icon name="hero-pencil" class="size-3" />
                  </button>
                  <button
                    id={"delete-option-#{option.id}"}
                    type="button"
                    phx-click="delete"
                    phx-value-id={option.id}
                    data-confirm="Delete this option?"
                    class="icon-btn"
                    aria-label={"Delete #{option.label}"}
                  >
                    <.icon name="hero-trash" class="size-3" />
                  </button>
                </div>
              </div>
            </div>

            <.form
              :if={@poll.status == :draft}
              for={@create_form}
              id="new-option-form"
              phx-change="validate-option"
              phx-submit="add-option"
              class="add-option"
            >
              <div class="min-w-0 flex-1">
                <.input
                  field={@create_form[:label]}
                  id="new-option-label"
                  type="text"
                  label="New option"
                  placeholder="Under the Sea"
                />
              </div>
              <button id="add-option-button" type="submit" class="btn btn-coral btn-sm">
                Add option
              </button>
            </.form>

            <.form
              :if={@edit_form}
              for={@edit_form}
              id="edit-option-form"
              phx-change="validate-edit-option"
              phx-submit="save-option"
              class="option-edit-form space-y-4"
            >
              <.input
                field={@edit_form[:label]}
                id="edit-option-label"
                type="text"
                label="Edit option"
              />
              <div class="flex justify-end gap-2">
                <button type="button" phx-click="cancel-edit" class="btn btn-ghost btn-sm">
                  Cancel
                </button>
                <button id="save-option-button" type="submit" class="btn btn-coral btn-sm">
                  Save option
                </button>
              </div>
            </.form>
          </div>

          <aside class="card card-pad" style="height:fit-content;">
            <h3>Draft checklist</h3>
            <ul>
              <li class="checklist-item done">
                <.icon name="hero-check-circle" class="size-5 text-success" /> Poll details saved
              </li>
              <li class={if(@option_count >= 2, do: "checklist-item done", else: "checklist-item")}>
                <.icon
                  name={if(@option_count >= 2, do: "hero-check-circle", else: "hero-minus-circle")}
                  class={
                    if(@option_count >= 2, do: "size-5 text-success", else: "size-5 text-warning")
                  }
                /> At least two options
              </li>
              <li class="checklist-item">
                <.icon name="hero-minus-circle" class="size-5" /> Configure the electorate next
              </li>
            </ul>
          </aside>
        </div>
      </section>
    </Layouts.app>
    """
  end

  @impl true
  def handle_event("validate-option", %{"option" => params}, socket) do
    params = create_params(socket, params)

    {:noreply,
     assign(socket, :create_form, AshPhoenix.Form.validate(socket.assigns.create_form, params))}
  end

  def handle_event("add-option", %{"option" => params}, socket) do
    params = create_params(socket, params)

    case AshPhoenix.Form.submit(socket.assigns.create_form, params: params) do
      {:ok, _option} ->
        {:noreply,
         socket |> put_flash(:info, "Option added") |> reload_options() |> assign_create_form()}

      {:error, form} ->
        {:noreply, assign(socket, :create_form, form)}
    end
  end

  def handle_event("edit", %{"id" => id}, socket) do
    option = Ash.get!(Option, id, actor: socket.assigns.current_user)

    form =
      option
      |> AshPhoenix.Form.for_update(:update, as: "option", actor: socket.assigns.current_user)
      |> to_form()

    {:noreply, assign(socket, editing_option_id: id, edit_form: form)}
  end

  def handle_event("validate-edit-option", %{"option" => params}, socket) do
    {:noreply,
     assign(socket, :edit_form, AshPhoenix.Form.validate(socket.assigns.edit_form, params))}
  end

  def handle_event("save-option", %{"option" => params}, socket) do
    case AshPhoenix.Form.submit(socket.assigns.edit_form, params: params) do
      {:ok, _option} ->
        {:noreply,
         socket
         |> put_flash(:info, "Option updated")
         |> assign(editing_option_id: nil, edit_form: nil)
         |> reload_options()}

      {:error, form} ->
        {:noreply, assign(socket, :edit_form, form)}
    end
  end

  def handle_event("cancel-edit", _params, socket) do
    {:noreply, assign(socket, editing_option_id: nil, edit_form: nil)}
  end

  def handle_event("delete", %{"id" => id}, socket) do
    option = Ash.get!(Option, id, actor: socket.assigns.current_user)
    Ash.destroy!(option, actor: socket.assigns.current_user)
    {:noreply, socket |> put_flash(:info, "Option deleted") |> reload_options()}
  end

  def handle_event("move", %{"id" => id, "direction" => direction}, socket) do
    actor = socket.assigns.current_user
    options = list_options(socket.assigns.poll, actor)
    index = Enum.find_index(options, &(&1.id == id))
    neighbor_index = if direction == "up", do: index - 1, else: index + 1

    with %Option{} = option <- Enum.at(options, index),
         %Option{} = neighbor <- Enum.at(options, neighbor_index) do
      swap_positions(option, neighbor, length(options) + 1, actor)
    end

    {:noreply, reload_options(socket)}
  end

  defp assign_create_form(socket) do
    form =
      AshPhoenix.Form.for_create(Option, :create,
        as: "option",
        actor: socket.assigns.current_user
      )

    assign(socket, :create_form, to_form(form))
  end

  defp create_params(socket, params) do
    params
    |> Map.put("poll_id", socket.assigns.poll.id)
    |> Map.put("position", next_position(socket.assigns.poll, socket.assigns.current_user))
  end

  defp next_position(poll, actor) do
    poll
    |> list_options(actor)
    |> Enum.map(& &1.position)
    |> Enum.max(fn -> 0 end)
    |> Kernel.+(1)
  end

  defp reload_options(socket) do
    options = list_options(socket.assigns.poll, socket.assigns.current_user)

    socket
    |> assign(:option_count, length(options))
    |> stream(:options, options, reset: true)
  end

  defp list_options(poll, actor) do
    Option
    |> Ash.Query.filter(poll_id == ^poll.id)
    |> Ash.Query.sort(position: :asc)
    |> Ash.read!(actor: actor)
  end

  defp swap_positions(option, neighbor, temporary_position, actor) do
    option_position = option.position
    neighbor_position = neighbor.position

    Polly.Repo.transaction(fn ->
      option = Ash.update!(option, %{position: temporary_position}, actor: actor)
      Ash.update!(neighbor, %{position: option_position}, actor: actor)
      Ash.update!(option, %{position: neighbor_position}, actor: actor)
    end)
  end
end
