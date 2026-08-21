defmodule PollyWeb.MemberLive.Index do
  use PollyWeb, :live_view

  require Ash.Query

  alias Polly.Members.Member

  on_mount {PollyWeb.LiveUserAuth, :live_user_required}

  @impl true
  def mount(_params, _session, socket) do
    members = list_members(socket.assigns.current_user)

    {:ok,
     socket
     |> assign(:page_title, "Members")
     |> assign(:member_count, length(members))
     |> assign(:editing_member_id, nil)
     |> assign(:edit_form, nil)
     |> assign_create_form()
     |> stream(:members, members)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} active_nav={:members}>
      <section id="members-index">
        <div class="admin-titlebar">
          <div>
            <div class="admin-h1">Members</div>
            <p class="admin-sub">Manage the roster used to build each poll's electorate.</p>
          </div>
          <span id="member-count" class="pill draft">{@member_count} members</span>
        </div>
        <div class="laneline" style="margin-bottom:20px;"></div>

        <div class="detail-grid">
          <div class="card card-pad">
            <h3>Member roster</h3>
            <div id="members" phx-update="stream">
              <div id="members-empty" class="empty-state hidden only:block">
                <h2>No members yet</h2>
                <p>Add a member to make them available for future polls.</p>
              </div>
              <div :for={{id, member} <- @streams.members} id={id} class="member-row">
                <div class="avatar">{initials(member.name)}</div>
                <div class="min-w-0 flex-1">
                  <strong>{member.name}</strong>
                  <div class="poll-meta">{member.email || "No email address"}</div>
                </div>
                <span class={if(member.active, do: "pill open", else: "pill closed")}>
                  {if(member.active, do: "Active", else: "Inactive")}
                </span>
                <button
                  id={"edit-member-#{member.id}"}
                  type="button"
                  phx-click="edit"
                  phx-value-id={member.id}
                  class="btn btn-ghost btn-sm"
                >
                  Edit
                </button>
              </div>
            </div>
          </div>

          <aside class="card card-pad" style="height:fit-content;">
            <h3>{if(@edit_form, do: "Edit member", else: "Add member")}</h3>
            <.form
              :if={!@edit_form}
              for={@create_form}
              id="new-member-form"
              phx-change="validate-new"
              phx-submit="create"
              class="space-y-4"
            >
              <.input field={@create_form[:name]} id="new-member-name" label="Name" />
              <.input
                field={@create_form[:email]}
                id="new-member-email"
                type="email"
                label="Email (optional)"
              />
              <button id="create-member-button" class="btn btn-coral" type="submit">
                Add member
              </button>
            </.form>

            <.form
              :if={@edit_form}
              for={@edit_form}
              id="edit-member-form"
              phx-change="validate-edit"
              phx-submit="save"
              class="space-y-4"
            >
              <.input field={@edit_form[:name]} id="edit-member-name" label="Name" />
              <.input
                field={@edit_form[:email]}
                id="edit-member-email"
                type="email"
                label="Email (optional)"
              />
              <.input
                field={@edit_form[:active]}
                id="edit-member-active"
                type="checkbox"
                label="Active member"
              />
              <div class="flex gap-2">
                <button id="save-member-button" class="btn btn-coral" type="submit">Save</button>
                <button type="button" class="btn btn-ghost" phx-click="cancel-edit">Cancel</button>
              </div>
            </.form>
          </aside>
        </div>
      </section>
    </Layouts.app>
    """
  end

  @impl true
  def handle_event("validate-new", %{"member" => params}, socket) do
    {:noreply,
     assign(socket, :create_form, AshPhoenix.Form.validate(socket.assigns.create_form, params))}
  end

  def handle_event("create", %{"member" => params}, socket) do
    case AshPhoenix.Form.submit(socket.assigns.create_form, params: params) do
      {:ok, _member} ->
        {:noreply, socket |> put_flash(:info, "Member added") |> reload() |> assign_create_form()}

      {:error, form} ->
        {:noreply, assign(socket, :create_form, form)}
    end
  end

  def handle_event("edit", %{"id" => id}, socket) do
    member = Ash.get!(Member, id, actor: socket.assigns.current_user)

    form =
      member
      |> AshPhoenix.Form.for_update(:update, as: "member", actor: socket.assigns.current_user)
      |> to_form()

    {:noreply, assign(socket, editing_member_id: member.id, edit_form: form)}
  end

  def handle_event("validate-edit", %{"member" => params}, socket) do
    {:noreply,
     assign(socket, :edit_form, AshPhoenix.Form.validate(socket.assigns.edit_form, params))}
  end

  def handle_event("save", %{"member" => params}, socket) do
    case AshPhoenix.Form.submit(socket.assigns.edit_form, params: params) do
      {:ok, _member} ->
        {:noreply,
         socket
         |> put_flash(:info, "Member updated")
         |> assign(editing_member_id: nil, edit_form: nil)
         |> reload()}

      {:error, form} ->
        {:noreply, assign(socket, :edit_form, form)}
    end
  end

  def handle_event("cancel-edit", _params, socket) do
    {:noreply, assign(socket, editing_member_id: nil, edit_form: nil)}
  end

  defp assign_create_form(socket) do
    form =
      AshPhoenix.Form.for_create(Member, :create,
        as: "member",
        actor: socket.assigns.current_user
      )

    assign(socket, :create_form, to_form(form))
  end

  defp reload(socket) do
    members = list_members(socket.assigns.current_user)
    socket |> assign(:member_count, length(members)) |> stream(:members, members, reset: true)
  end

  defp list_members(actor) do
    Member |> Ash.Query.sort(name: :asc) |> Ash.read!(actor: actor)
  end

  defp initials(name) do
    name |> String.split() |> Enum.take(2) |> Enum.map_join(&String.first/1) |> String.upcase()
  end
end
