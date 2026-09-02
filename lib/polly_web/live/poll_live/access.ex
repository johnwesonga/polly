defmodule PollyWeb.PollLive.Access do
  @moduledoc """
  Manages voter access and invitation delivery for a poll.

  The LiveView exposes grant lifecycle and delivery status without rendering
  working voter credentials. Access requires the `:manage_access_grants`
  permission, while invitation events apply their additional authorization.
  """

  use PollyWeb, :live_view

  require Ash.Query

  alias Polly.Polls.{AccessGrant, Eligibility, Electorate, Invitations, Poll}

  on_mount {PollyWeb.LiveUserAuth, {:require_permission, :manage_access_grants}}

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    actor = socket.assigns.current_user
    poll = Ash.get!(Poll, id, actor: actor)

    {:ok,
     socket
     |> assign(:page_title, "#{poll.title} voter access")
     |> assign(:poll, poll)
     |> assign(:confirming_bulk?, false)
     |> assign(:status_refresh_scheduled?, false)
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
              Deliver, revoke, or reissue private member access.
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
          <span class="phase-tab current">Voter access</span>
          <.link navigate={~p"/admin/polls/#{@poll.id}/results"} class="phase-tab">Results</.link>
        </div>

        <div id="protected-voting-credentials" class="callout green">
          <.icon name="hero-shield-check" class="size-5" />
          <span>
            Voting links are delivered directly to members and cannot be viewed or copied by
            administrators.
          </span>
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
              phx-click="prepare-invitations"
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
          <div
            :if={@skip_reason_counts != []}
            id="invitation-skip-breakdown"
            class="invitation-skip-breakdown"
          >
            <span :for={{state, count} <- @skip_reason_counts} class="invitation-skip-reason">
              <strong>{count}</strong> {state_label(state)}
            </span>
          </div>
        </div>

        <div
          :if={@confirming_bulk?}
          id="invitation-confirmation-overlay"
          class="invitation-confirmation-overlay"
          phx-window-keydown="cancel-invitations"
          phx-key="escape"
        >
          <section
            id="invitation-confirmation"
            class="card card-pad invitation-confirmation"
            role="dialog"
            aria-modal="true"
            aria-labelledby="invitation-confirmation-title"
          >
            <div class="m-eyebrow">Email invitations</div>
            <h2 id="invitation-confirmation-title" class="admin-h2">Confirm bulk send</h2>
            <p class="admin-sub">
              Queue private voting links for <strong>{@poll.title}</strong>.
            </p>
            <dl class="invitation-confirmation-counts">
              <div>
                <dt>Will be queued</dt>
                <dd>{@invitation_preview.ready_count}</dd>
              </div>
              <div>
                <dt>Will be skipped</dt>
                <dd>{@invitation_preview.skipped_count}</dd>
              </div>
            </dl>
            <div :if={@skip_reason_counts != []} class="invitation-confirmation-reasons">
              <div :for={{state, count} <- @skip_reason_counts}>
                <span>{state_label(state)}</span><strong>{count}</strong>
              </div>
            </div>
            <div class="callout amber invitation-private-warning">
              <.icon name="hero-key" class="size-5" />
              <span>Each email contains that member's private voting link.</span>
            </div>
            <div class="invitation-confirmation-actions">
              <button
                id="cancel-email-invitations"
                type="button"
                phx-click="cancel-invitations"
                class="btn btn-outline"
              >
                Cancel
              </button>
              <button
                id="confirm-email-invitations"
                type="button"
                phx-click="send-invitations"
                class="btn btn-coral"
              >
                Queue {@invitation_preview.ready_count} invitation(s)
              </button>
            </div>
          </section>
        </div>

        <div class="card card-pad">
          <div id="access-members" phx-update="stream">
            <div id="access-members-empty" class="empty-state hidden only:block">
              <h2>No eligible members</h2>
              <p>Select an electorate first; private access is issued for every selected member.</p>
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
                  class={[
                    "pill",
                    invitation_status_class(Map.fetch!(@invitation_recipients, eligibility.member_id))
                  ]}
                >
                  {invitation_state_label(Map.fetch!(@invitation_recipients, eligibility.member_id))}
                </span>
              </div>
              <% recipient = Map.fetch!(@invitation_recipients, eligibility.member_id) %>
              <div
                :if={invitation_status_detail(recipient)}
                id={"invitation-detail-#{eligibility.member_id}"}
                class="invitation-status-detail"
              >
                {invitation_status_detail(recipient)}
              </div>
              <div
                :if={grant = Map.get(@grants_by_member, eligibility.member_id)}
                class="access-link-controls"
              >
                <div
                  id={"protected-access-#{eligibility.member_id}"}
                  class="access-protected-message"
                >
                  <.icon name="hero-lock-closed" class="size-4" />
                  <span>Private credential hidden · deliver by email</span>
                </div>
                <div class="access-actions">
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
                    :if={resend_action?(recipient)}
                    id={"resend-invitation-#{eligibility.member_id}"}
                    type="button"
                    phx-click="resend-invitation"
                    phx-value-id={grant.id}
                    data-confirm="Queue another invitation for this member?"
                    class="btn btn-outline btn-sm"
                  >
                    {resend_label(recipient)}
                  </button>
                  <button
                    id={"revoke-access-link-#{eligibility.member_id}"}
                    type="button"
                    phx-click="revoke"
                    phx-value-id={grant.id}
                    data-confirm="Revoke this member's voting access? Their current emailed link will stop working."
                    class="btn btn-outline btn-sm access-revoke"
                  >
                    Revoke
                  </button>
                  <button
                    id={"reissue-access-link-#{eligibility.member_id}"}
                    type="button"
                    phx-click="reissue"
                    phx-value-id={grant.id}
                    data-confirm="Reissue this member's access? Their current emailed link will stop working and the replacement must be emailed."
                    class="btn btn-coral btn-sm"
                  >
                    Reissue access
                  </button>
                </div>
              </div>
              <div
                :if={!Map.has_key?(@grants_by_member, eligibility.member_id)}
                class="access-revoked-message"
              >
                This member's previous credential no longer grants access.
              </div>
              <button
                :if={!Map.has_key?(@grants_by_member, eligibility.member_id)}
                id={"issue-access-link-#{eligibility.member_id}"}
                type="button"
                phx-click="issue"
                phx-value-member-id={eligibility.member_id}
                class="btn btn-coral btn-sm access-issue"
              >
                Issue access
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
    grant = get_safe_grant!(id, socket.assigns.current_user)
    Electorate.revoke(grant, socket.assigns.current_user)
    {:noreply, socket |> put_flash(:info, "Voting access revoked") |> load_access()}
  end

  def handle_event("reissue", %{"id" => id}, socket) do
    grant = get_safe_grant!(id, socket.assigns.current_user)
    Electorate.reissue(grant, socket.assigns.current_user)

    {:noreply,
     socket |> put_flash(:info, "Voting access reissued; email the replacement") |> load_access()}
  end

  def handle_event("issue", %{"member-id" => member_id}, socket) do
    Electorate.issue(socket.assigns.poll.id, member_id, socket.assigns.current_user)

    {:noreply,
     socket |> put_flash(:info, "Voting access issued; email the credential") |> load_access()}
  end

  def handle_event("send-invitations", _params, socket) do
    case Invitations.enqueue_bulk(socket.assigns.poll, socket.assigns.current_user) do
      {:ok, deliveries} ->
        {:noreply,
         socket
         |> assign(:confirming_bulk?, false)
         |> put_flash(:info, "Queued #{length(deliveries)} email invitation(s)")
         |> load_access()}

      {:error, :poll_not_open} ->
        {:noreply, put_flash(socket, :error, "Open the poll before sending invitations")}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Invitations could not be queued")}
    end
  end

  def handle_event("prepare-invitations", _params, socket) do
    if socket.assigns.poll.status == :open && socket.assigns.invitation_preview.ready_count > 0 do
      {:noreply, assign(socket, :confirming_bulk?, true)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("cancel-invitations", _params, socket) do
    {:noreply, assign(socket, :confirming_bulk?, false)}
  end

  def handle_event("send-invitation", %{"id" => id}, socket) do
    enqueue_one(socket, id, :initial)
  end

  def handle_event("resend-invitation", %{"id" => id}, socket) do
    enqueue_one(socket, id, :resend)
  end

  @impl true
  def handle_info(:refresh_invitation_status, socket) do
    {:noreply, socket |> assign(:status_refresh_scheduled?, false) |> load_access()}
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
      |> Ash.Query.select([:id, :poll_id, :member_id, :revoked_at, :expires_at, :inserted_at])
      |> Ash.Query.sort(inserted_at: :desc)
      |> Ash.read!(actor: actor)

    grants_by_member = Map.new(grants, &{&1.member_id, &1})
    invitation_preview = Invitations.preview(poll, actor)

    invitation_recipients =
      Map.new(invitation_preview.recipients, &{&1.member.id, &1})

    socket =
      socket
      |> assign(:grants_by_member, grants_by_member)
      |> assign(:active_grant_count, map_size(grants_by_member))
      |> assign(:eligible_count, length(eligibilities))
      |> assign(:invitation_preview, invitation_preview)
      |> assign(:skip_reason_counts, skip_reason_counts(invitation_preview.counts))
      |> assign(:invitation_recipients, invitation_recipients)
      |> stream(:eligibilities, eligibilities, reset: true)

    maybe_schedule_status_refresh(socket, invitation_preview.recipients)
  end

  defp enqueue_one(socket, grant_id, kind) do
    grant = get_safe_grant!(grant_id, socket.assigns.current_user)

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

  defp invitation_status_class(%{delivery: %{status: :accepted}}), do: "open"

  defp invitation_status_class(%{delivery: %{status: status}})
       when status in [:failed, :cancelled],
       do: "closed"

  defp invitation_status_class(_recipient), do: nil

  defp invitation_status_detail(%{
         delivery: %{status: :accepted},
         latest_accepted_at: accepted_at
       })
       when not is_nil(accepted_at) do
    "Provider accepted #{format_datetime(accepted_at)} · Inbox delivery is not confirmed."
  end

  defp invitation_status_detail(%{delivery: %{status: status, last_error_code: code}})
       when status in [:failed, :cancelled] and not is_nil(code) do
    error_label(code)
  end

  defp invitation_status_detail(_recipient), do: nil

  defp resend_action?(%{state: :already_invited, delivery: %{status: status}}),
    do: status in [:accepted, :failed, :cancelled]

  defp resend_action?(_recipient), do: false

  defp resend_label(%{delivery: %{status: status}}) when status in [:failed, :cancelled],
    do: "Retry email"

  defp resend_label(_recipient), do: "Resend email"

  defp error_label("timeout"), do: "Delivery timed out after repeated attempts."
  defp error_label("rate_limited"), do: "The email provider rate-limited delivery."
  defp error_label("provider_unavailable"), do: "The email provider was unavailable."
  defp error_label("recipient_rejected"), do: "The recipient address was rejected."
  defp error_label("configuration_error"), do: "Email delivery is not configured correctly."
  defp error_label("provider_error"), do: "The email provider rejected delivery."
  defp error_label("poll_not_open"), do: "Cancelled because the poll is no longer open."
  defp error_label("member_inactive"), do: "Cancelled because the member is inactive."
  defp error_label("recipient_changed"), do: "Cancelled because the member email changed."
  defp error_label("grant_revoked"), do: "Cancelled because the access link was revoked."

  defp error_label("stale_credential"),
    do: "Cancelled because a newer voting credential was issued."

  defp error_label("grant_expired"), do: "Cancelled because the access link expired."
  defp error_label("already_voted"), do: "Cancelled because the member already voted."
  defp error_label(_code), do: "Delivery could not be completed."

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

  defp skip_reason_counts(counts) do
    [
      :already_invited,
      :already_voted,
      :missing_email,
      :inactive_member,
      :missing_grant,
      :revoked_grant,
      :expired_grant,
      :poll_not_open
    ]
    |> Enum.flat_map(fn state ->
      case Map.get(counts, state, 0) do
        0 -> []
        count -> [{state, count}]
      end
    end)
  end

  defp format_datetime(datetime) do
    Calendar.strftime(datetime, "%b %-d, %Y at %-I:%M %p UTC")
  end

  defp get_safe_grant!(id, actor) do
    AccessGrant
    |> Ash.Query.filter(id == ^id)
    |> Ash.Query.select([:id, :poll_id, :member_id, :revoked_at, :expires_at, :inserted_at])
    |> Ash.read_one!(actor: actor)
  end

  defp maybe_schedule_status_refresh(socket, recipients) do
    in_flight? =
      Enum.any?(recipients, fn
        %{delivery: %{status: status}} when status in [:queued, :sending] -> true
        _recipient -> false
      end)

    if connected?(socket) && in_flight? && !socket.assigns.status_refresh_scheduled? do
      Process.send_after(self(), :refresh_invitation_status, 2_000)
      assign(socket, :status_refresh_scheduled?, true)
    else
      socket
    end
  end

  defp initials(name) do
    name |> String.split() |> Enum.take(2) |> Enum.map_join(&String.first/1) |> String.upcase()
  end
end
