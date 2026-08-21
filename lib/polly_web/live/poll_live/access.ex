defmodule PollyWeb.PollLive.Access do
  use PollyWeb, :live_view

  require Ash.Query

  alias Polly.Polls.{AccessGrant, Eligibility, Electorate, Poll}

  on_mount {PollyWeb.LiveUserAuth, :live_user_required}

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    actor = socket.assigns.current_user
    poll = Ash.get!(Poll, id, actor: actor)

    {:ok,
     socket
     |> assign(:page_title, "#{poll.title} access links")
     |> assign(:poll, poll)
     |> load_access()}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} active_nav={:polls}>
      <section id="poll-access-page">
        <div class="breadcrumb">
          <.link navigate={~p"/admin/polls"}>Polls</.link><span>/</span><span>{@poll.title}</span>
        </div>
        <div class="detail-header">
          <div>
            <div class="admin-h1">{String.upcase(@poll.title)}</div>
            <p class="admin-sub" style="margin:4px 0 0;">
              Copy, revoke, or reissue private member links.
            </p>
          </div>
          <span id="active-grant-count" class="pill open">{@active_grant_count} active</span>
        </div>

        <div class="detail-tabs" aria-label="Poll configuration sections">
          <.link navigate={~p"/admin/polls/#{@poll.id}/options"} class="phase-tab">Options</.link>
          <.link navigate={~p"/admin/polls/#{@poll.id}/electorate"} class="phase-tab">
            Electorate
          </.link>
          <span class="phase-tab current">Access links</span>
          <span class="phase-tab">Results · Phase 4</span>
        </div>

        <div class="callout amber">
          <.icon name="hero-key" class="size-5" />
          <span>Each link is a credential for one member and one poll. Share it privately.</span>
        </div>

        <div class="card card-pad">
          <div id="access-members" phx-update="stream">
            <div id="access-members-empty" class="empty-state hidden only:block">
              <h2>No eligible members</h2>
              <p>Select an electorate first; a link is generated for every selected member.</p>
            </div>
            <div
              :for={{id, eligibility} <- @streams.eligibilities}
              id={id}
              class="member-row access-row"
            >
              <div class="avatar">{initials(eligibility.member.name)}</div>
              <div class="min-w-0 flex-1">
                <strong>{eligibility.member.name}</strong>
                <div class="poll-meta">{eligibility.member.email || "No email address"}</div>
                <div
                  :if={grant = Map.get(@grants_by_member, eligibility.member_id)}
                  class="flex gap-2 mt-2"
                >
                  <input
                    id={"access-link-#{eligibility.member_id}"}
                    class="input link-token min-w-0 flex-1"
                    readonly
                    value={access_path(@poll, grant)}
                    aria-label={"Voting link for #{eligibility.member.name}"}
                  />
                  <button
                    id={"copy-access-link-#{eligibility.member_id}"}
                    type="button"
                    class="btn btn-outline btn-sm"
                    phx-click={JS.dispatch("phx:copy", to: "#access-link-#{eligibility.member_id}")}
                  >
                    Copy
                  </button>
                </div>
                <div
                  :if={!Map.has_key?(@grants_by_member, eligibility.member_id)}
                  class="poll-meta mt-2"
                >
                  Link revoked
                </div>
              </div>
              <div :if={grant = Map.get(@grants_by_member, eligibility.member_id)} class="flex gap-2">
                <button
                  id={"revoke-access-link-#{eligibility.member_id}"}
                  type="button"
                  phx-click="revoke"
                  phx-value-id={grant.id}
                  data-confirm="Revoke this voting link?"
                  class="btn btn-ghost btn-sm"
                >
                  Revoke
                </button>
                <button
                  id={"reissue-access-link-#{eligibility.member_id}"}
                  type="button"
                  phx-click="reissue"
                  phx-value-id={grant.id}
                  data-confirm="Reissue this link? The current link will stop working."
                  class="btn btn-coral btn-sm"
                >
                  Reissue
                </button>
              </div>
              <button
                :if={!Map.has_key?(@grants_by_member, eligibility.member_id)}
                id={"issue-access-link-#{eligibility.member_id}"}
                type="button"
                phx-click="issue"
                phx-value-member-id={eligibility.member_id}
                class="btn btn-coral btn-sm"
              >
                Issue new link
              </button>
            </div>
          </div>
        </div>
      </section>
    </Layouts.app>
    """
  end

  @impl true
  def handle_event("revoke", %{"id" => id}, socket) do
    grant = Ash.get!(AccessGrant, id, actor: socket.assigns.current_user)
    Ash.update!(grant, %{}, action: :revoke, actor: socket.assigns.current_user)
    {:noreply, socket |> put_flash(:info, "Access link revoked") |> load_access()}
  end

  def handle_event("reissue", %{"id" => id}, socket) do
    grant = Ash.get!(AccessGrant, id, actor: socket.assigns.current_user)
    Electorate.reissue(grant, socket.assigns.current_user)
    {:noreply, socket |> put_flash(:info, "Access link reissued") |> load_access()}
  end

  def handle_event("issue", %{"member-id" => member_id}, socket) do
    Ash.create!(
      AccessGrant,
      %{poll_id: socket.assigns.poll.id, member_id: member_id},
      actor: socket.assigns.current_user
    )

    {:noreply, socket |> put_flash(:info, "Access link issued") |> load_access()}
  end

  defp load_access(socket) do
    actor = socket.assigns.current_user
    poll = socket.assigns.poll

    eligibilities =
      Eligibility
      |> Ash.Query.filter(poll_id == ^poll.id)
      |> Ash.Query.load(:member)
      |> Ash.read!(actor: actor)
      |> Enum.sort_by(&String.downcase(&1.member.name))

    grants =
      AccessGrant
      |> Ash.Query.filter(poll_id == ^poll.id and is_nil(revoked_at))
      |> Ash.Query.sort(inserted_at: :desc)
      |> Ash.read!(actor: actor)

    grants_by_member = Map.new(grants, &{&1.member_id, &1})

    socket
    |> assign(:grants_by_member, grants_by_member)
    |> assign(:active_grant_count, map_size(grants_by_member))
    |> stream(:eligibilities, eligibilities, reset: true)
  end

  defp access_path(poll, grant), do: "/polls/#{poll.id}/vote/#{grant.token}"

  defp initials(name) do
    name |> String.split() |> Enum.take(2) |> Enum.map_join(&String.first/1) |> String.upcase()
  end
end
