defmodule PollyWeb.AdministratorLive do
  @moduledoc "Owner-only administrator account management interface."

  use PollyWeb, :live_view

  on_mount {PollyWeb.LiveUserAuth, {:require_permission, :manage_administrators}}

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, :page_title, "Administrators")}
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
      </section>
    </Layouts.app>
    """
  end
end
