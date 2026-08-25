defmodule PollyWeb.PollLive.Access do
  use PollyWeb, :live_view

  require Ash.Query

  alias Polly.Polls.{AccessGrant, Eligibility, Electorate, Invitations, Poll}

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
            <div class="admin-h2">{String.upcase(@poll.title)}</div>
            <p class="admin-sub" style="margin:4px 0 0;">
              Copy, revoke, or reissue private member links.
            </p>
          </div>
          <span id="active-grant-count" class="pill open">
            {@active_grant_count} of {@eligible_count} active
          </span>
        </div>

        <div class="detail-tabs" aria-label="Poll configuration sections">
          <.link navigate={~p"/admin/polls/#{@poll.id}/options"} class="phase-tab">Options</.link>
          <.link navigate={~p"/admin/polls/#{@poll.id}/electorate"} class="phase-tab">
            Electorate
          </.link>
          <span class="phase-tab current">Access links</span>
          <.link navigate={~p"/admin/polls/#{@poll.id}/results"} class="phase-tab">Results</.link>
        </div>

        <div class="callout amber">
          <.icon name="hero-key" class="size-5" />
          <span>Each link is a credential for one member and one poll. Share it privately.</span>
        </div>

        <div id="email-invitations" class="card card-pad" style="margin-bottom:16px;">
          <div class="detail-header">
            <div>
              <div class="admin-h3">Email invitations</div>
              <p class="admin-sub" style="margin:4px 0 0;">
                Send each ready member their private voting link.
              </p>
            </div>
            <button
              id="send-email-invitations"
              type="button"
              phx-click="send-invitations"
              data-confirm={
                "Queue #{@invitation_preview.ready_count} private email invitation(s)?"
              }
              disabled={@poll.status != :open || @invitation_preview.ready_count == 0}
              class="btn btn-coral btn-sm"
            >
              Send invitations
            </button>
          </div>
          <div id="invitation-readiness" class="poll-meta">
            {@invitation_preview.ready_count} ready · {@invitation_preview.skipped_count} skipped
            <%= if @poll.status != :open do %>
              · Open the poll before sending invitations
            <% end %>
          </div>
        </div>

        <div class="card card-pad">
          <div id="access-members" phx-update="stream">
            <div id="access-members-empty" class="empty-state hidden only:block">
              <h2>No eligible members</h2>
              <p>Select an electorate first; a link is generated for every selected member.</p>
              <.link
                id="configure-electorate-link"
                navigate={~p"/admin/polls/#{@poll.id}/electorate"}
                class="btn btn-coral btn-sm mt-4"
              >
                Configure electorate
              </.link>
            </div>
            <div
              :for={{id, eligibility} <- @streams.eligibilities}
              id={id}
              class="member-row access-row"
            >
              <div class="access-member-heading">
                <div class="avatar">{initials(eligibility.member.name)}</div>
                <div class="access-member-identity">
                  <strong>{eligibility.member.name}</strong>
                  <div class="poll-meta">{eligibility.member.email || "No email address"}</div>
                </div>
                <span class={
                  if(Map.has_key?(@grants_by_member, eligibility.member_id),
                    do: "pill open",
                    else: "pill closed"
                  )
                }>
                  {if(Map.has_key?(@grants_by_member, eligibility.member_id),
                    do: "Active",
                    else: "Revoked"
                  )}
                </span>
                <span
                  id={"invitation-status-#{eligibility.member_id}"}
                  class="pill"
                >
                  {invitation_state_label(Map.fetch!(@invitation_recipients, eligibility.member_id))}
                </span>
              </div>
              <div
                :if={grant = Map.get(@grants_by_member, eligibility.member_id)}
                class="access-link-controls"
              >
                <code
                  id={"access-link-#{eligibility.member_id}"}
                  class="access-url-preview"
                  title={access_url(@poll, grant)}
                  data-url={access_url(@poll, grant)}
                >
                  {access_url_preview(@poll, grant)}
                </code>
                <button
                  id={"copy-access-link-#{eligibility.member_id}"}
                  type="button"
                  class="btn btn-outline btn-sm"
                  phx-click={JS.dispatch("phx:copy")}
                  data-copy-value={access_url(@poll, grant)}
                  aria-live="polite"
                >
                  Copy
                </button>
                <div class="access-actions">
                  <% recipient = Map.fetch!(@invitation_recipients, eligibility.member_id) %>
                  <button
                    :if={recipient.state == :ready}
                    id={"send-invitation-#{eligibility.member_id}"}
                    type="button"
                    phx-click="send-invitation"
                    phx-value-id={grant.id}
                    class="btn btn-outline btn-sm"
                  >
                    Email link
                  </button>
                  <button
                    :if={recipient.state == :already_invited}
                    id={"resend-invitation-#{eligibility.member_id}"}
                    type="button"
                    phx-click="resend-invitation"
                    phx-value-id={grant.id}
                    data-confirm="Queue another invitation for this member?"
                    class="btn btn-outline btn-sm"
                  >
                    Resend email
                  </button>
                  <button
                    id={"revoke-access-link-#{eligibility.member_id}"}
                    type="button"
                    phx-click="revoke"
                    phx-value-id={grant.id}
                    data-confirm="Revoke this voting link?"
                    class="btn btn-outline btn-sm access-revoke"
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
              </div>
              <div
                :if={!Map.has_key?(@grants_by_member, eligibility.member_id)}
                class="access-revoked-message"
              >
                This link no longer grants access.
              </div>
              <button
                :if={!Map.has_key?(@grants_by_member, eligibility.member_id)}
                id={"issue-access-link-#{eligibility.member_id}"}
                type="button"
                phx-click="issue"
                phx-value-member-id={eligibility.member_id}
                class="btn btn-coral btn-sm access-issue"
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
    Electorate.revoke(grant, socket.assigns.current_user)
    {:noreply, socket |> put_flash(:info, "Access link revoked") |> load_access()}
  end

  def handle_event("reissue", %{"id" => id}, socket) do
    grant = Ash.get!(AccessGrant, id, actor: socket.assigns.current_user)
    Electorate.reissue(grant, socket.assigns.current_user)
    {:noreply, socket |> put_flash(:info, "Access link reissued") |> load_access()}
  end

  def handle_event("issue", %{"member-id" => member_id}, socket) do
    Electorate.issue(socket.assigns.poll.id, member_id, socket.assigns.current_user)

    {:noreply, socket |> put_flash(:info, "Access link issued") |> load_access()}
  end

  def handle_event("send-invitations", _params, socket) do
    case Invitations.enqueue_bulk(socket.assigns.poll, socket.assigns.current_user) do
      {:ok, deliveries} ->
        {:noreply,
         socket
         |> put_flash(:info, "Queued #{length(deliveries)} email invitation(s)")
         |> load_access()}

      {:error, :poll_not_open} ->
        {:noreply, put_flash(socket, :error, "Open the poll before sending invitations")}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Invitations could not be queued")}
    end
  end

  def handle_event("send-invitation", %{"id" => id}, socket) do
    enqueue_one(socket, id, :initial)
  end

  def handle_event("resend-invitation", %{"id" => id}, socket) do
    enqueue_one(socket, id, :resend)
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
    invitation_preview = Invitations.preview(poll, actor)

    invitation_recipients =
      Map.new(invitation_preview.recipients, &{&1.member.id, &1})

    socket
    |> assign(:grants_by_member, grants_by_member)
    |> assign(:active_grant_count, map_size(grants_by_member))
    |> assign(:eligible_count, length(eligibilities))
    |> assign(:invitation_preview, invitation_preview)
    |> assign(:invitation_recipients, invitation_recipients)
    |> stream(:eligibilities, eligibilities, reset: true)
  end

  defp enqueue_one(socket, grant_id, kind) do
    grant = Ash.get!(AccessGrant, grant_id, actor: socket.assigns.current_user)

    case Invitations.enqueue_one(grant, socket.assigns.current_user, kind) do
      {:ok, _delivery} ->
        {:noreply,
         socket
         |> put_flash(:info, "Email invitation queued")
         |> load_access()}

      {:error, reason} when is_atom(reason) ->
        {:noreply, put_flash(socket, :error, "Invitation unavailable: #{state_label(reason)}")}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Invitation could not be queued")}
    end
  end

  defp invitation_state_label(%{delivery: %{status: status}}), do: delivery_status_label(status)
  defp invitation_state_label(%{state: state}), do: state_label(state)

  defp delivery_status_label(:queued), do: "Queued"
  defp delivery_status_label(:sending), do: "Sending"
  defp delivery_status_label(:accepted), do: "Sent"
  defp delivery_status_label(:failed), do: "Failed"
  defp delivery_status_label(:cancelled), do: "Cancelled"

  defp state_label(:ready), do: "Ready to email"
  defp state_label(:poll_not_open), do: "Poll not open"
  defp state_label(:missing_email), do: "Missing email"
  defp state_label(:inactive_member), do: "Inactive member"
  defp state_label(:already_voted), do: "Already voted"
  defp state_label(:missing_grant), do: "Missing grant"
  defp state_label(:revoked_grant), do: "Revoked grant"
  defp state_label(:expired_grant), do: "Expired grant"
  defp state_label(:already_invited), do: "Already invited"
  defp state_label(:not_eligible), do: "Not eligible"

  defp access_url(poll, grant) do
    PollyWeb.Endpoint.url() <> "/polls/#{poll.id}/vote/#{grant.token}"
  end

  defp access_url_preview(_poll, grant) do
    "Voting link · " <> String.slice(grant.token, 0, 30) <> "…"
  end

  defp initials(name) do
    name |> String.split() |> Enum.take(2) |> Enum.map_join(&String.first/1) |> String.upcase()
  end
end
