defmodule PollyWeb.AdministratorLive do
  @moduledoc "Owner-only administrator account management interface."

  use PollyWeb, :live_view

  alias Polly.Accounts.User

  require Ash.Query

  on_mount {PollyWeb.LiveUserAuth, {:require_permission, :manage_administrators}}

  @impl true
  def mount(_params, _session, socket) do
    accounts = list_accounts(socket.assigns.current_user)

    {:ok,
     socket
     |> assign(:page_title, "Administrators")
     |> assign(:account_count, length(accounts))
     |> stream_configure(:administrator_accounts, dom_id: &"administrator-account-#{&1.id}")
     |> stream(:administrator_accounts, accounts)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <section id="administrator-management-page">
        <div class="admin-titlebar">
          <div>
            <div class="admin-h1">Administrators</div>
            <p class="admin-sub">Manage administrator access, roles, and account status.</p>
          </div>
        </div>
        <div class="laneline"></div>

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
          </article>
        </div>
      </section>
    </Layouts.app>
    """
  end

  defp list_accounts(actor) do
    User
    |> Ash.Query.sort(inserted_at: :asc, email: :asc)
    |> Ash.read!(actor: actor)
  end

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
