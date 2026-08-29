defmodule PollyWeb.AdminLive do
  use PollyWeb, :live_view

  on_mount {PollyWeb.LiveUserAuth, :live_user_required}

  @impl true
  def mount(_params, _session, socket) do
    actor = socket.assigns.current_user

    {:ok,
     socket
     |> assign(:page_title, "Administration")
     |> assign(:quick_actions, quick_actions(actor))}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} active_nav={:overview}>
      <section id="admin-overview">
        <header class="dashboard-heading">
          <div class="dashboard-heading-copy">
            <div class="admin-h1">Overview</div>
            <p class="admin-sub">Here’s what needs your attention today.</p>
            <div class="laneline"></div>
          </div>

          <nav
            :if={@quick_actions != []}
            id="dashboard-quick-actions"
            class="dashboard-quick-actions"
            aria-label="Quick actions"
          >
            <%= for action <- @quick_actions do %>
              <.link
                :if={!action.external?}
                id={action.id}
                navigate={action.path}
                class={action.class}
              >
                <.icon name={action.icon} class="size-4" /> {action.label}
              </.link>
              <.link
                :if={action.external?}
                id={action.id}
                href={action.path}
                class={action.class}
              >
                <.icon name={action.icon} class="size-4" /> {action.label}
              </.link>
            <% end %>
          </nav>
        </header>
      </section>
    </Layouts.app>
    """
  end

  defp quick_actions(actor) do
    actions =
      if Polly.Accounts.Authorization.allowed?(actor, :manage_polls) do
        [
          action(
            actor,
            :manage_polls,
            "create-poll-action",
            "Create poll",
            ~p"/admin/polls/new",
            "hero-plus",
            "btn btn-coral"
          ),
          action(
            actor,
            :manage_members,
            "import-members-action",
            "Import members",
            ~p"/admin/members/import",
            "hero-arrow-up-tray",
            "btn btn-outline"
          )
        ]
      else
        [
          action(
            actor,
            :view_results,
            "view-results-action",
            "View poll results",
            ~p"/admin/polls",
            "hero-chart-bar",
            "btn btn-outline"
          ),
          action(
            actor,
            :view_audit,
            "view-audit-action",
            "View audit trail",
            ~p"/admin/audit",
            "hero-document-text",
            "btn btn-outline"
          ),
          action(
            actor,
            :view_jobs,
            "view-jobs-action",
            "View background jobs",
            ~p"/admin/oban",
            "hero-circle-stack",
            "btn btn-outline",
            external?: true
          )
        ]
      end

    actions
    |> Enum.reject(&is_nil/1)
  end

  defp action(actor, permission, id, label, path, icon, class, options \\ []) do
    allowed? = Polly.Accounts.Authorization.allowed?(actor, permission)

    if allowed? do
      %{
        id: id,
        label: label,
        path: path,
        icon: icon,
        class: class,
        external?: Keyword.get(options, :external?, false)
      }
    end
  end
end
