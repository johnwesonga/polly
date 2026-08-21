defmodule PollyWeb.PollLive.Electorate do
  use PollyWeb, :live_view

  require Ash.Query

  alias Polly.Members.Member
  alias Polly.Polls.{Eligibility, Electorate, Option, Poll}

  on_mount {PollyWeb.LiveUserAuth, :live_user_required}

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    actor = socket.assigns.current_user
    poll = Ash.get!(Poll, id, actor: actor)
    members = list_members(actor)
    options = list_options(poll, actor)
    eligibilities = list_eligibilities(poll, actor)

    {:ok,
     socket
     |> assign(:page_title, "#{poll.title} electorate")
     |> assign(:poll, poll)
     |> assign(:eligible_ids, MapSet.new(eligibilities, & &1.member_id))
     |> assign(:eligible_count, length(eligibilities))
     |> stream(:members, members)
     |> stream(:preview_options, options)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} active_nav={:polls}>
      <section id="poll-electorate-page">
        <div class="breadcrumb">
          <.link navigate={~p"/admin/polls"}>Polls</.link><span>/</span><span>{@poll.title}</span>
        </div>
        <div class="detail-header">
          <div>
            <div class="admin-h1">{String.upcase(@poll.title)}</div>
            <p class="admin-sub" style="margin:4px 0 0;">Choose who may vote in this poll.</p>
          </div>
          <span class={"pill #{@poll.status}"}>{@poll.status}</span>
        </div>

        <div class="detail-tabs" aria-label="Poll configuration sections">
          <.link navigate={~p"/admin/polls/#{@poll.id}/options"} class="phase-tab">Options</.link>
          <span class="phase-tab current">Electorate</span>
          <.link navigate={~p"/admin/polls/#{@poll.id}/access"} class="phase-tab">Access links</.link>
          <span class="phase-tab">Results · Phase 4</span>
        </div>

        <div :if={@poll.status != :draft} id="electorate-frozen-notice" class="callout amber">
          <.icon name="hero-lock-closed" class="size-5" />
          <span>The electorate is frozen because this poll is no longer a draft.</span>
        </div>

        <div class="detail-grid">
          <div class="card card-pad">
            <div class="flex items-center justify-between gap-3" style="margin-bottom:12px;">
              <div>
                <h3 style="margin:0;">Eligible members</h3>
                <div id="eligible-count" class="poll-meta">{@eligible_count} selected</div>
              </div>
              <button
                :if={@poll.status == :draft}
                id="select-all-members"
                type="button"
                phx-click="select-all"
                class="btn btn-outline btn-sm"
              >
                Select all active
              </button>
            </div>

            <div id="electorate-members" phx-update="stream">
              <div id="electorate-members-empty" class="empty-state hidden only:block">
                <h2>No members available</h2>
                <p>Add members to the roster before configuring the electorate.</p>
              </div>
              <div :for={{id, member} <- @streams.members} id={id} class="member-row">
                <div class="avatar">{initials(member.name)}</div>
                <div class="min-w-0 flex-1">
                  <strong>{member.name}</strong>
                  <div class="poll-meta">{member.email || "No email address"}</div>
                </div>
                <span :if={!member.active} class="pill closed">Inactive</span>
                <button
                  :if={@poll.status == :draft and member.active}
                  id={"toggle-eligibility-#{member.id}"}
                  type="button"
                  phx-click="toggle"
                  phx-value-id={member.id}
                  class={
                    if(MapSet.member?(@eligible_ids, member.id),
                      do: "btn btn-coral btn-sm",
                      else: "btn btn-outline btn-sm"
                    )
                  }
                >
                  {if(MapSet.member?(@eligible_ids, member.id), do: "Selected", else: "Select")}
                </button>
                <span
                  :if={@poll.status != :draft and MapSet.member?(@eligible_ids, member.id)}
                  class="pill open"
                >
                  Eligible
                </span>
              </div>
            </div>
          </div>

          <aside id="ballot-preview" class="card card-pad" style="height:fit-content;">
            <div class="poll-meta">Ballot preview</div>
            <h3>{@poll.title}</h3>
            <p :if={@poll.description} class="admin-sub">{@poll.description}</p>
            <div id="preview-options" phx-update="stream" class="space-y-2">
              <div id="preview-options-empty" class="empty-state hidden only:block">
                No options configured.
              </div>
              <div :for={{id, option} <- @streams.preview_options} id={id} class="option-row">
                <span class="size-4 rounded-full border border-current"></span>
                <span>{option.label}</span>
              </div>
            </div>
          </aside>
        </div>
      </section>
    </Layouts.app>
    """
  end

  @impl true
  def handle_event("toggle", %{"id" => member_id}, socket) do
    actor = socket.assigns.current_user

    if MapSet.member?(socket.assigns.eligible_ids, member_id) do
      eligibility = get_eligibility!(socket.assigns.poll.id, member_id, actor)
      Electorate.exclude_member(socket.assigns.poll, eligibility, actor)
    else
      member = Ash.get!(Member, member_id, actor: actor)
      Electorate.include_member(socket.assigns.poll, member, actor)
    end

    {:noreply, reload_eligibilities(socket)}
  end

  def handle_event("select-all", _params, socket) do
    actor = socket.assigns.current_user

    actor
    |> list_members()
    |> Enum.filter(&(&1.active and not MapSet.member?(socket.assigns.eligible_ids, &1.id)))
    |> Enum.each(&Electorate.include_member(socket.assigns.poll, &1, actor))

    {:noreply, reload_eligibilities(socket)}
  end

  defp reload_eligibilities(socket) do
    actor = socket.assigns.current_user
    eligibilities = list_eligibilities(socket.assigns.poll, actor)

    socket
    |> assign(:eligible_ids, MapSet.new(eligibilities, & &1.member_id))
    |> assign(:eligible_count, length(eligibilities))
    |> stream(:members, list_members(actor), reset: true)
  end

  defp list_members(actor) do
    Member |> Ash.Query.sort(name: :asc) |> Ash.read!(actor: actor)
  end

  defp list_options(poll, actor) do
    Option
    |> Ash.Query.filter(poll_id == ^poll.id and active == true)
    |> Ash.Query.sort(position: :asc)
    |> Ash.read!(actor: actor)
  end

  defp list_eligibilities(poll, actor) do
    Eligibility |> Ash.Query.filter(poll_id == ^poll.id) |> Ash.read!(actor: actor)
  end

  defp get_eligibility!(poll_id, member_id, actor) do
    Eligibility
    |> Ash.Query.filter(poll_id == ^poll_id and member_id == ^member_id)
    |> Ash.read_one!(actor: actor)
  end

  defp initials(name) do
    name |> String.split() |> Enum.take(2) |> Enum.map_join(&String.first/1) |> String.upcase()
  end
end
