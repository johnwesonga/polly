defmodule PollyWeb.AdminLive do
  use PollyWeb, :live_view

  on_mount {PollyWeb.LiveUserAuth, :live_user_required}

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, :page_title, "Administration")}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} active_nav={:overview}>
      <section id="admin-overview">
        <div class="admin-titlebar">
          <div class="admin-h1">Overview</div>
        </div>
        <p class="admin-sub">Configure independent polls and prepare their ballot options.</p>
        <div class="laneline"></div>

        <div id="poll-management-card" class="card card-pad" style="margin-top:20px; max-width:620px;">
          <h3>Poll management</h3>
          <p class="admin-sub" style="margin-bottom:16px;">
            Create draft polls, edit their details, and manage ordered text options.
          </p>
          <.link id="manage-polls-link" navigate={~p"/admin/polls"} class="btn btn-coral">
            Manage polls
          </.link>
        </div>
      </section>
    </Layouts.app>
    """
  end
end
