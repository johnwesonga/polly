defmodule PollyWeb.AdminLive do
  use PollyWeb, :live_view

  on_mount {PollyWeb.LiveUserAuth, :live_user_required}

  @impl true
  def mount(_params, _session, socket) do
    actor = socket.assigns.current_user

    {:ok,
     socket
     |> assign(:page_title, "Administration")
     |> assign(:manage_polls?, Polly.Accounts.Authorization.allowed?(actor, :manage_polls))
     |> assign(:view_results?, Polly.Accounts.Authorization.allowed?(actor, :view_results))
     |> assign(:view_jobs?, Polly.Accounts.Authorization.allowed?(actor, :view_jobs))}
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

        <div
          :if={@manage_polls? || @view_results?}
          id="poll-management-card"
          class="card card-pad"
          style="margin-top:20px; max-width:620px;"
        >
          <h3>Poll management</h3>
          <p class="admin-sub" style="margin-bottom:16px;">
            Create draft polls, edit their details, and manage ordered text options.
          </p>
          <.link id="manage-polls-link" navigate={~p"/admin/polls"} class="btn btn-coral">
            {if(@manage_polls?, do: "Manage polls", else: "View poll results")}
          </.link>
        </div>
        <div
          :if={@view_jobs?}
          id="job-monitoring-card"
          class="card card-pad"
          style="margin-top:20px; max-width:620px;"
        >
          <h3>Background jobs</h3>
          <p class="admin-sub" style="margin-bottom:16px;">
            Inspect queue health and email delivery work in read-only mode.
          </p>
          <.link id="view-jobs-link" href={~p"/admin/oban"} class="btn btn-coral">
            View background jobs
          </.link>
        </div>
      </section>
    </Layouts.app>
    """
  end
end
