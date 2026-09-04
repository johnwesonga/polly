defmodule PollyWeb.MemberLive.Index do
  use PollyWeb, :live_view

  require Ash.Query

  alias Polly.Members.Member

  on_mount {PollyWeb.LiveUserAuth, {:require_permission, :manage_members}}

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Members")
     |> assign(:member_count, 0)
     |> assign(:matching_member_count, 0)
     |> assign(:filtered?, false)
     |> assign(:filter_params, %{})
     |> assign(:filter_form, to_form(%{"q" => "", "status" => "all"}, as: :filters))
     |> assign(:page_params, %{})
     |> assign(:previous_cursor, nil)
     |> assign(:next_cursor, nil)
     |> assign(:editing_member_id, nil)
     |> assign(:edit_form, nil)
     |> assign_create_form()
     |> stream(:members, [])}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    case list_members(socket.assigns.current_user, params) do
      {:ok, page, matching_count, total_count} ->
        {:noreply, assign_page(socket, page, params, matching_count, total_count)}

      {:error, _error} ->
        {:noreply, push_patch(socket, to: ~p"/admin/members")}
    end
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
          <div class="flex items-center gap-3">
            <span id="member-count" class="pill draft">{@member_count} members</span>
            <.link id="import-members-link" navigate={~p"/admin/members/import"} class="btn btn-coral">
              Import CSV
            </.link>
          </div>
        </div>
        <div class="laneline" style="margin-bottom:20px;"></div>

        <div class="detail-grid">
          <div class="card card-pad">
            <h3>Member roster</h3>
            <.form
              for={@filter_form}
              id="member-filter-form"
              phx-change="filter"
              class="mb-5 grid gap-3 md:grid-cols-[minmax(0,1fr)_12rem_auto] md:items-end"
            >
              <.input
                field={@filter_form[:q]}
                id="member-search"
                type="search"
                label="Find a member"
                placeholder="Search by name or email"
                autocomplete="off"
                phx-debounce="300"
              />
              <.input
                field={@filter_form[:status]}
                id="member-status-filter"
                type="select"
                label="Status"
                options={[
                  {"All members", "all"},
                  {"Active", "active"},
                  {"Inactive", "inactive"}
                ]}
              />
              <.link
                :if={@filtered?}
                id="clear-member-filters"
                patch={~p"/admin/members"}
                class="btn btn-ghost btn-sm"
              >
                Clear filters
              </.link>
            </.form>
            <p :if={@filtered?} id="member-filter-count" class="poll-meta mb-3">
              {@matching_member_count} matching · {@member_count} total
            </p>
            <div id="members" phx-update="stream">
              <div id="members-empty" class="empty-state hidden only:block">
                <%= if @filtered? do %>
                  <h2>No matching members</h2>
                  <p>Try another name, email address, or member status.</p>
                <% else %>
                  <h2>No members yet</h2>
                  <p>Add a member to make them available for future polls.</p>
                <% end %>
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

            <nav
              :if={@previous_cursor || @next_cursor}
              id="member-pagination"
              class="poll-actions"
              aria-label="Member pages"
            >
              <.link
                :if={@previous_cursor}
                id="previous-members-page"
                patch={pagination_path(:before, @previous_cursor, @filter_params)}
                class="btn btn-outline btn-sm"
              >
                Previous
              </.link>
              <.link
                :if={@next_cursor}
                id="next-members-page"
                patch={pagination_path(:after, @next_cursor, @filter_params)}
                class="btn btn-outline btn-sm"
              >
                Next
              </.link>
            </nav>
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

  def handle_event("filter", %{"filters" => filters}, socket) do
    {:noreply, push_patch(socket, to: filter_path(filters), replace: true)}
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
    case list_members(socket.assigns.current_user, socket.assigns.page_params) do
      {:ok, page, matching_count, total_count} ->
        assign_page(
          socket,
          page,
          socket.assigns.page_params,
          matching_count,
          total_count
        )

      {:error, _error} ->
        push_patch(socket, to: ~p"/admin/members")
    end
  end

  defp assign_page(socket, page, params, matching_count, total_count) do
    filters = filter_params(params)

    socket
    |> assign(:member_count, total_count)
    |> assign(:matching_member_count, matching_count)
    |> assign(:filtered?, filters != %{})
    |> assign(:filter_params, filters)
    |> assign(
      :filter_form,
      to_form(
        %{"q" => Map.get(filters, "q", ""), "status" => Map.get(filters, "status", "all")},
        as: :filters
      )
    )
    |> assign(:page_params, Map.take(params, ["q", "status", "after", "before"]))
    |> assign(:previous_cursor, previous_cursor(page))
    |> assign(:next_cursor, next_cursor(page))
    |> stream(:members, page.results, reset: true)
  end

  defp list_members(actor, params) do
    query =
      Member
      |> apply_search(params)
      |> apply_status(params)
      |> Ash.Query.sort(name: :asc, id: :asc)

    with {:ok, page} <- Ash.read(query, actor: actor, page: page_options(params)) do
      {:ok, page, Ash.count!(query, actor: actor), Ash.count!(Member, actor: actor)}
    end
  end

  defp apply_search(query, %{"q" => value}) when is_binary(value) do
    search = value |> String.trim() |> String.slice(0, 320) |> String.downcase()

    if String.length(search) >= 2 do
      Ash.Query.filter(
        query,
        contains(string_downcase(name), ^search) or
          contains(string_downcase(email), ^search)
      )
    else
      query
    end
  end

  defp apply_search(query, _params), do: query

  defp apply_status(query, %{"status" => "active"}), do: Ash.Query.filter(query, active == true)

  defp apply_status(query, %{"status" => "inactive"}),
    do: Ash.Query.filter(query, active == false)

  defp apply_status(query, _params), do: query

  defp pagination_path(direction, cursor, filters) do
    params = Map.put(filters, Atom.to_string(direction), cursor)
    ~p"/admin/members?#{params}"
  end

  defp filter_path(filters) do
    params = filter_params(filters)
    ~p"/admin/members?#{params}"
  end

  defp filter_params(params) do
    %{}
    |> maybe_put_search(Map.get(params, "q"))
    |> maybe_put_status(Map.get(params, "status"))
  end

  defp maybe_put_search(params, value) when is_binary(value) do
    case String.trim(value) do
      "" -> params
      search -> Map.put(params, "q", String.slice(search, 0, 320))
    end
  end

  defp maybe_put_search(params, _value), do: params

  defp maybe_put_status(params, status) when status in ["active", "inactive"],
    do: Map.put(params, "status", status)

  defp maybe_put_status(params, _status), do: params

  defp page_options(%{"after" => cursor}) when is_binary(cursor) and cursor != "",
    do: [after: cursor]

  defp page_options(%{"before" => cursor}) when is_binary(cursor) and cursor != "",
    do: [before: cursor]

  defp page_options(_params), do: []

  defp previous_cursor(%Ash.Page.Keyset{results: []}), do: nil

  defp previous_cursor(%Ash.Page.Keyset{results: results, after: after_cursor})
       when not is_nil(after_cursor),
       do: keyset(List.first(results))

  defp previous_cursor(%Ash.Page.Keyset{results: results, before: before_cursor, more?: true})
       when not is_nil(before_cursor),
       do: keyset(List.first(results))

  defp previous_cursor(_page), do: nil

  defp next_cursor(%Ash.Page.Keyset{results: []}), do: nil

  defp next_cursor(%Ash.Page.Keyset{results: results, before: before_cursor})
       when not is_nil(before_cursor),
       do: keyset(List.last(results))

  defp next_cursor(%Ash.Page.Keyset{results: results, more?: true}),
    do: keyset(List.last(results))

  defp next_cursor(_page), do: nil

  defp keyset(record), do: record.__metadata__.keyset

  defp initials(name) do
    name |> String.split() |> Enum.take(2) |> Enum.map_join(&String.first/1) |> String.upcase()
  end
end
