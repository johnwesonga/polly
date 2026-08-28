defmodule PollyWeb.AdministratorLive do
  @moduledoc "Owner-only administrator account management interface."

  use PollyWeb, :live_view

  alias Polly.Accounts.{AdministratorInvitation, AdministratorInvitations, Administrators, User}

  require Ash.Query

  on_mount {PollyWeb.LiveUserAuth, {:require_permission, :manage_administrators}}

  @impl true
  def mount(_params, _session, socket) do
    accounts = list_accounts(socket.assigns.current_user)
    invitations = list_pending_invitations(socket.assigns.current_user)

    {:ok,
     socket
     |> assign(:page_title, "Administrators")
     |> assign(:pending_action, nil)
     |> assign(:pending_invite, nil)
     |> assign(:pending_invitation_action, nil)
     |> assign(:invite_form, invite_form())
     |> assign(:account_count, length(accounts))
     |> assign(:active_owner_count, active_owner_count(accounts))
     |> stream_configure(:administrator_accounts, dom_id: &"administrator-account-#{&1.id}")
     |> stream_configure(:administrator_invitations, dom_id: &"administrator-invitation-#{&1.id}")
     |> stream(:administrator_invitations, invitations)
     |> stream(:administrator_accounts, accounts)}
  end

  @impl true
  def handle_event("invite-administrator", %{"invitation" => params}, socket) do
    if params["role"] == "owner" do
      {:noreply, assign(socket, :pending_invite, params)}
    else
      perform_invite(socket, params)
    end
  end

  def handle_event("cancel-owner-invitation", _params, socket) do
    {:noreply, assign(socket, :pending_invite, nil)}
  end

  def handle_event("confirm-owner-invitation", _params, socket) do
    params = socket.assigns.pending_invite
    perform_invite(assign(socket, :pending_invite, nil), params)
  end

  def handle_event("request-invitation-action", %{"id" => id, "operation" => operation}, socket)
      when operation in ["resend", "renew", "revoke"] do
    case Ash.get(AdministratorInvitation, id, actor: socket.assigns.current_user) do
      {:ok, invitation} ->
        {:noreply,
         assign(socket, :pending_invitation_action, %{
           invitation: invitation,
           operation: String.to_existing_atom(operation)
         })}

      _ ->
        {:noreply, put_flash(socket, :error, "Administrator invitation not found.")}
    end
  end

  def handle_event("cancel-invitation-action", _params, socket) do
    {:noreply, assign(socket, :pending_invitation_action, nil)}
  end

  def handle_event(
        "confirm-invitation-action",
        _params,
        %{assigns: %{pending_invitation_action: nil}} = socket
      ) do
    {:noreply, socket}
  end

  def handle_event("confirm-invitation-action", _params, socket) do
    pending = socket.assigns.pending_invitation_action
    actor = socket.assigns.current_user

    result =
      case pending.operation do
        :resend -> AdministratorInvitations.resend(pending.invitation, actor)
        :renew -> AdministratorInvitations.renew(pending.invitation, actor)
        :revoke -> AdministratorInvitations.revoke(pending.invitation, actor)
      end

    case result do
      {:ok, _invitation} ->
        {:noreply,
         socket
         |> assign(:pending_invitation_action, nil)
         |> put_flash(:info, invitation_success(pending.operation))
         |> refresh_invitations()}

      {:error, reason} ->
        {:noreply,
         socket
         |> assign(:pending_invitation_action, nil)
         |> put_flash(:error, invitation_action_error(reason))
         |> refresh_invitations()}
    end
  end

  @impl true
  def handle_event("request-status-change", %{"id" => id, "operation" => operation}, socket)
      when operation in ["enable", "disable"] do
    with {:ok, account} <- fetch_account(id, socket.assigns.current_user) do
      {:noreply,
       assign(socket, :pending_action, %{
         operation: String.to_existing_atom(operation),
         account: account,
         role: nil
       })}
    else
      _ -> {:noreply, put_flash(socket, :error, "Administrator account not found.")}
    end
  end

  def handle_event("request-role-change", %{"account" => params}, socket) do
    with %{"id" => id, "role" => role} <- params,
         {:ok, role} <- cast_role(role),
         {:ok, account} <- fetch_account(id, socket.assigns.current_user) do
      if account.role == role do
        {:noreply, put_flash(socket, :info, "The account already has that role.")}
      else
        {:noreply,
         assign(socket, :pending_action, %{
           operation: :change_role,
           account: account,
           role: role
         })}
      end
    else
      _ -> {:noreply, put_flash(socket, :error, "Select a valid role.")}
    end
  end

  def handle_event("cancel-account-action", _params, socket) do
    {:noreply, assign(socket, :pending_action, nil)}
  end

  def handle_event("confirm-account-action", _params, %{assigns: %{pending_action: nil}} = socket) do
    {:noreply, socket}
  end

  def handle_event("confirm-account-action", _params, socket) do
    pending = socket.assigns.pending_action
    actor = socket.assigns.current_user

    result =
      case pending.operation do
        :enable -> Administrators.enable(pending.account, actor)
        :disable -> Administrators.disable(pending.account, actor)
        :change_role -> Administrators.change_role(pending.account, pending.role, actor)
      end

    case result do
      {:ok, _account} ->
        {:noreply,
         socket
         |> assign(:pending_action, nil)
         |> put_flash(:info, success_message(pending))
         |> refresh_accounts()}

      {:error, reason} ->
        {:noreply,
         socket
         |> assign(:pending_action, nil)
         |> put_flash(:error, error_message(reason))
         |> refresh_accounts()}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} active_nav={:administrators}>
      <section id="administrator-management-page">
        <div class="admin-titlebar">
          <div>
            <div class="admin-h1">Administrators</div>
            <p class="admin-sub">Manage administrator access, roles, and account status.</p>
          </div>
        </div>
        <div class="laneline"></div>

        <section id="administrator-invitations-section" class="card card-pad form-card">
          <div class="m-eyebrow">Invite administrator</div>
          <h2 class="admin-h2">Send a private setup link</h2>
          <p class="admin-sub">The recipient chooses their own password. You will never see it.</p>
          <.form
            for={@invite_form}
            id="administrator-invitation-form"
            phx-submit="invite-administrator"
          >
            <.input field={@invite_form[:email]} type="email" label="Email address" required />
            <.input field={@invite_form[:role]} type="select" label="Role" options={role_options()} />
            <div class="form-actions">
              <button id="send-administrator-invitation" type="submit" class="btn btn-coral">
                Send invitation
              </button>
            </div>
          </.form>

          <div id="administrator-invitations" class="administrator-directory" phx-update="stream">
            <div id="administrator-invitations-empty" class="empty-state hidden only:block">
              <p>No pending invitations.</p>
            </div>
            <div
              :for={{id, invitation} <- @streams.administrator_invitations}
              id={id}
              class="poll-card"
            >
              <div>
                <div class="poll-name">{invitation.email}</div>
                <div class="poll-meta">Expires {format_datetime(invitation.expires_at)}</div>
              </div>
              <span class="pill draft">{role_label(invitation.role)}</span>
              <span class={invitation_delivery_class(invitation.delivery_status)}>
                {invitation_delivery_label(invitation.delivery_status)}
              </span>
              <div class="poll-actions">
                <button
                  id={"resend-administrator-invitation-#{invitation.id}"}
                  type="button"
                  class="btn btn-ghost btn-sm"
                  phx-click="request-invitation-action"
                  phx-value-id={invitation.id}
                  phx-value-operation="resend"
                >
                  Resend
                </button>
                <button
                  id={"renew-administrator-invitation-#{invitation.id}"}
                  type="button"
                  class="btn btn-outline btn-sm"
                  phx-click="request-invitation-action"
                  phx-value-id={invitation.id}
                  phx-value-operation="renew"
                >
                  Renew
                </button>
                <button
                  id={"revoke-administrator-invitation-#{invitation.id}"}
                  type="button"
                  class="btn btn-outline btn-sm"
                  phx-click="request-invitation-action"
                  phx-value-id={invitation.id}
                  phx-value-operation="revoke"
                >
                  Revoke
                </button>
              </div>
            </div>
          </div>
        </section>

        <div class="administrator-directory-heading">
          <div>
            <h2 class="admin-h2">Accounts</h2>
            <p class="admin-sub">{@account_count} administrator accounts</p>
          </div>
        </div>

        <div
          id="administrator-accounts"
          class="administrator-directory"
          phx-update="stream"
        >
          <div id="administrator-accounts-empty" class="empty-state hidden only:block">
            <h2>No administrator accounts</h2>
            <p>Create an owner from a trusted release shell to restore access.</p>
          </div>

          <article
            :for={{dom_id, account} <- @streams.administrator_accounts}
            id={dom_id}
            class="card administrator-account-row"
          >
            <div class="administrator-account-identity">
              <div class="administrator-account-email">
                {to_string(account.email)}
                <span
                  :if={account.id == @current_scope.user.id}
                  id={"administrator-account-you-#{account.id}"}
                  class="pill draft"
                >
                  You
                </span>
              </div>
              <div class="poll-meta">Created {format_datetime(account.inserted_at)}</div>
            </div>

            <div class="administrator-account-field">
              <span>Role</span>
              <strong id={"administrator-account-role-#{account.id}"}>
                {role_label(account.role)}
              </strong>
            </div>

            <div class="administrator-account-field">
              <span>Status</span>
              <span
                id={"administrator-account-status-#{account.id}"}
                class={[
                  "pill",
                  account.status == :active && "published",
                  account.status == :disabled && "closed"
                ]}
              >
                {status_label(account.status)}
              </span>
            </div>

            <div class="administrator-account-field">
              <span>Confirmation</span>
              <strong id={"administrator-account-confirmation-#{account.id}"}>
                {confirmation_label(account)}
              </strong>
            </div>

            <div class="administrator-account-field administrator-account-sign-in">
              <span>Last sign-in</span>
              <strong id={"administrator-account-last-sign-in-#{account.id}"}>
                {format_optional_datetime(account.last_signed_in_at)}
              </strong>
            </div>

            <div class="administrator-account-actions">
              <.form
                for={role_form(account)}
                id={"administrator-role-form-#{account.id}"}
                phx-submit="request-role-change"
              >
                <input type="hidden" name="account[id]" value={account.id} />
                <.input
                  field={role_form(account)[:role]}
                  id={"administrator-role-select-#{account.id}"}
                  type="select"
                  label="Change role"
                  options={role_options()}
                  disabled={final_active_owner?(account, @active_owner_count)}
                />
                <button
                  id={"administrator-change-role-#{account.id}"}
                  type="submit"
                  class="btn btn-ghost btn-sm"
                  disabled={final_active_owner?(account, @active_owner_count)}
                >
                  Change role
                </button>
              </.form>

              <button
                :if={account.status == :active}
                id={"administrator-disable-#{account.id}"}
                type="button"
                class="btn btn-coral btn-sm"
                phx-click="request-status-change"
                phx-value-id={account.id}
                phx-value-operation="disable"
                disabled={disable_forbidden?(account, @current_scope.user, @active_owner_count)}
                title={disable_explanation(account, @current_scope.user, @active_owner_count)}
              >
                Disable
              </button>
              <button
                :if={account.status == :disabled}
                id={"administrator-enable-#{account.id}"}
                type="button"
                class="btn btn-ghost btn-sm"
                phx-click="request-status-change"
                phx-value-id={account.id}
                phx-value-operation="enable"
              >
                Enable
              </button>

              <p
                :if={final_active_owner?(account, @active_owner_count)}
                id={"administrator-owner-protection-#{account.id}"}
                class="field-help"
              >
                Add another active owner before disabling or changing this account's role.
              </p>
            </div>
          </article>
        </div>

        <div
          :if={@pending_invitation_action}
          id="invitation-action-confirmation-overlay"
          class="invitation-confirmation-overlay"
          phx-window-keydown="cancel-invitation-action"
          phx-key="escape"
        >
          <section
            id="invitation-action-confirmation"
            class="card card-pad invitation-confirmation"
            role="dialog"
            aria-modal="true"
            aria-labelledby="invitation-action-confirmation-title"
          >
            <div class="m-eyebrow">Administrator invitation</div>
            <h2 id="invitation-action-confirmation-title" class="admin-h2">
              {invitation_action_title(@pending_invitation_action.operation)}
            </h2>
            <p class="admin-sub">{invitation_action_message(@pending_invitation_action)}</p>
            <div class="invitation-confirmation-actions">
              <button
                id="cancel-invitation-action"
                type="button"
                class="btn btn-outline"
                phx-click="cancel-invitation-action"
              >
                Cancel
              </button>
              <button
                id="confirm-invitation-action"
                type="button"
                class="btn btn-coral"
                phx-click="confirm-invitation-action"
              >
                Confirm
              </button>
            </div>
          </section>
        </div>

        <div
          :if={@pending_invite}
          id="owner-invitation-confirmation-overlay"
          class="invitation-confirmation-overlay"
        >
          <section
            class="card card-pad invitation-confirmation"
            role="dialog"
            aria-modal="true"
            aria-labelledby="owner-invitation-title"
          >
            <div class="m-eyebrow">Administrator invitation</div>
            <h2 id="owner-invitation-title" class="admin-h2">Grant owner access?</h2>
            <p class="admin-sub">
              {@pending_invite["email"]} will receive full access, including administrator management.
            </p>
            <div class="invitation-confirmation-actions">
              <button
                id="cancel-owner-invitation"
                type="button"
                class="btn btn-outline"
                phx-click="cancel-owner-invitation"
              >
                Cancel
              </button>
              <button
                id="confirm-owner-invitation"
                type="button"
                class="btn btn-coral"
                phx-click="confirm-owner-invitation"
              >
                Send owner invitation
              </button>
            </div>
          </section>
        </div>

        <div
          :if={@pending_action}
          id="administrator-action-confirmation-overlay"
          class="invitation-confirmation-overlay"
          phx-window-keydown="cancel-account-action"
          phx-key="escape"
        >
          <section
            id="administrator-action-confirmation"
            class="card card-pad invitation-confirmation"
            role="dialog"
            aria-modal="true"
            aria-labelledby="administrator-action-confirmation-title"
          >
            <div class="m-eyebrow">Administrator management</div>
            <h2 id="administrator-action-confirmation-title" class="admin-h2">
              {confirmation_title(@pending_action)}
            </h2>
            <p class="admin-sub">{confirmation_message(@pending_action)}</p>
            <div class="invitation-confirmation-actions">
              <button
                id="cancel-administrator-action"
                type="button"
                class="btn btn-outline"
                phx-click="cancel-account-action"
              >
                Cancel
              </button>
              <button
                id="confirm-administrator-action"
                type="button"
                class="btn btn-coral"
                phx-click="confirm-account-action"
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

  defp perform_invite(socket, params) do
    case AdministratorInvitations.invite(
           params["email"],
           params["role"],
           socket.assigns.current_user
         ) do
      {:ok, _invitation} ->
        {:noreply,
         socket
         |> assign(:invite_form, invite_form())
         |> put_flash(:info, "Administrator invitation queued.")
         |> refresh_invitations()}

      {:error, reason} ->
        {:noreply,
         socket
         |> assign(:invite_form, invite_form(params))
         |> put_flash(:error, invitation_error(reason))}
    end
  end

  defp list_accounts(actor) do
    User
    |> Ash.Query.sort(inserted_at: :asc, email: :asc)
    |> Ash.read!(actor: actor)
  end

  defp list_pending_invitations(actor) do
    AdministratorInvitation
    |> Ash.Query.filter(status == :pending and expires_at > ^DateTime.utc_now())
    |> Ash.Query.sort(inserted_at: :desc)
    |> Ash.read!(actor: actor)
  end

  defp refresh_invitations(socket) do
    stream(
      socket,
      :administrator_invitations,
      list_pending_invitations(socket.assigns.current_user),
      reset: true
    )
  end

  defp invite_form(params \\ %{"email" => "", "role" => "administrator"}) do
    to_form(params, as: :invitation)
  end

  defp invitation_error(:existing_user),
    do: "An account already exists for that email. Enable it instead if needed."

  defp invitation_error(:pending_invitation),
    do: "A pending invitation already exists for that email."

  defp invitation_error(:invalid_email), do: "Enter a valid email address."
  defp invitation_error(:invalid_role), do: "Select a valid role."
  defp invitation_error(:unauthorized), do: "You are not allowed to invite administrators."
  defp invitation_error(_reason), do: "The invitation could not be created."

  defp invitation_success(:resend), do: "Administrator invitation queued again."
  defp invitation_success(:renew), do: "Administrator invitation renewed for seven days."
  defp invitation_success(:revoke), do: "Administrator invitation revoked."

  defp invitation_action_error(:expired), do: "The invitation has expired. Renew it instead."
  defp invitation_action_error(:not_pending), do: "The invitation is no longer pending."
  defp invitation_action_error(:invitation_not_found), do: "Administrator invitation not found."
  defp invitation_action_error(_reason), do: "The invitation could not be updated."

  defp invitation_action_title(:resend), do: "Resend invitation?"
  defp invitation_action_title(:renew), do: "Renew invitation?"
  defp invitation_action_title(:revoke), do: "Revoke invitation?"

  defp invitation_action_message(%{operation: :resend, invitation: invitation}),
    do: "Queue another email to #{invitation.email} without changing its expiry."

  defp invitation_action_message(%{operation: :renew, invitation: invitation}),
    do: "Revoke the current link for #{invitation.email} and issue a new seven-day invitation."

  defp invitation_action_message(%{operation: :revoke, invitation: invitation}),
    do: "Permanently invalidate the pending setup link for #{invitation.email}."

  defp invitation_delivery_label(:queued), do: "Queued"
  defp invitation_delivery_label(:sending), do: "Sending"
  defp invitation_delivery_label(:sent), do: "Sent"
  defp invitation_delivery_label(:failed), do: "Failed"

  defp invitation_delivery_class(:sent), do: "pill published"
  defp invitation_delivery_class(:failed), do: "pill open"
  defp invitation_delivery_class(_status), do: "pill draft"

  defp refresh_accounts(socket) do
    accounts = list_accounts(socket.assigns.current_user)

    socket
    |> assign(:account_count, length(accounts))
    |> assign(:active_owner_count, active_owner_count(accounts))
    |> stream(:administrator_accounts, accounts, reset: true)
  end

  defp fetch_account(id, actor), do: Ash.get(User, id, actor: actor)

  defp cast_role(role) do
    case Ash.Type.cast_input(User.Role, role) do
      {:ok, role} -> {:ok, role}
      _ -> {:error, :invalid_role}
    end
  end

  defp role_form(account), do: to_form(%{"role" => to_string(account.role)}, as: :account)

  defp role_options do
    [
      {"Owner", :owner},
      {"Administrator", :administrator},
      {"Auditor", :auditor},
      {"Operator", :operator}
    ]
  end

  defp active_owner_count(accounts) do
    Enum.count(accounts, &(&1.role == :owner and &1.status == :active))
  end

  defp final_active_owner?(account, count) do
    account.role == :owner and account.status == :active and count == 1
  end

  defp disable_forbidden?(account, actor, owner_count) do
    account.id == actor.id or final_active_owner?(account, owner_count)
  end

  defp disable_explanation(account, actor, owner_count) do
    cond do
      account.id == actor.id -> "You cannot disable your own account."
      final_active_owner?(account, owner_count) -> "The final active owner cannot be disabled."
      true -> nil
    end
  end

  defp confirmation_title(%{operation: :enable}), do: "Enable administrator?"
  defp confirmation_title(%{operation: :disable}), do: "Disable administrator?"
  defp confirmation_title(%{operation: :change_role, role: :owner}), do: "Grant owner access?"
  defp confirmation_title(%{operation: :change_role}), do: "Change administrator role?"

  defp confirmation_message(%{operation: :enable, account: account}) do
    "#{account.email} will regain access to Polly."
  end

  defp confirmation_message(%{operation: :disable, account: account}) do
    "#{account.email} will lose access and all of their active sessions will be revoked."
  end

  defp confirmation_message(%{operation: :change_role, account: account, role: :owner}) do
    "#{account.email} will receive full owner access, including administrator management."
  end

  defp confirmation_message(%{operation: :change_role, account: account, role: role}) do
    "Change #{account.email} from #{role_label(account.role)} to #{role_label(role)}? Their active sessions will be revoked."
  end

  defp success_message(%{operation: :enable}), do: "Administrator enabled."
  defp success_message(%{operation: :disable}), do: "Administrator disabled."
  defp success_message(%{operation: :change_role}), do: "Administrator role changed."

  defp error_message(:cannot_disable_self), do: "You cannot disable your own account."
  defp error_message(:last_active_owner), do: "Polly must retain at least one active owner."
  defp error_message(:target_not_found), do: "Administrator account not found."
  defp error_message(:unauthorized), do: "You are not allowed to manage administrators."
  defp error_message(:invalid_role), do: "Select a valid role."
  defp error_message(_reason), do: "The administrator account could not be updated."

  defp role_label(:owner), do: "Owner"
  defp role_label(:administrator), do: "Administrator"
  defp role_label(:auditor), do: "Auditor"
  defp role_label(:operator), do: "Operator"

  defp status_label(:active), do: "Active"
  defp status_label(:disabled), do: "Disabled"

  defp confirmation_label(%User{confirmed_at: nil}), do: "Unconfirmed"
  defp confirmation_label(%User{}), do: "Confirmed"

  defp format_optional_datetime(nil), do: "Never"
  defp format_optional_datetime(datetime), do: format_datetime(datetime)

  defp format_datetime(datetime) do
    Calendar.strftime(datetime, "%b %-d, %Y at %-I:%M %p UTC")
  end
end
