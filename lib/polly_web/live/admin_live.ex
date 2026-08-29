defmodule PollyWeb.AdminLive do
  use PollyWeb, :live_view

  on_mount {PollyWeb.LiveUserAuth, :live_user_required}

  @impl true
  def mount(_params, _session, socket) do
    actor = socket.assigns.current_user
    dashboard = load_dashboard(actor)

    {:ok,
     socket
     |> assign(:page_title, "Administration")
     |> assign(:poll_counts, dashboard.poll_counts)
     |> assign(:attention_items, dashboard.attention_items)
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

        <section :if={@attention_items != nil} id="dashboard-attention" class="dashboard-section">
          <h2 class="dashboard-section-heading">Action required</h2>
          <div
            :if={@attention_items == []}
            id="dashboard-attention-empty"
            class="card dashboard-attention-empty"
          >
            <span class="dashboard-attention-ok"><.icon name="hero-check-circle" /></span>
            <div>
              <strong>Nothing needs attention</strong>
              <p>Poll configuration and results are up to date.</p>
            </div>
          </div>
          <div :if={@attention_items != []} class="dashboard-attention-grid">
            <article
              :for={item <- @attention_items}
              id={"dashboard-attention-#{item.kind}"}
              class={[
                "card",
                "dashboard-attention-card",
                item.kind == :failed_deliveries && "critical"
              ]}
            >
              <span class="dashboard-attention-icon"><.icon name="hero-exclamation-triangle" /></span>
              <div>
                <h3>{attention_title(item)}</h3>
                <p>{attention_description(item.kind)}</p>
                <.link navigate={item.destination} class="dashboard-card-link">
                  {attention_link(item.kind)} <.icon name="hero-arrow-right" />
                </.link>
              </div>
            </article>
          </div>
        </section>

        <section :if={@poll_counts} id="dashboard-poll-summary" class="dashboard-section">
          <h2 class="dashboard-section-heading">Poll summary</h2>
          <div class="dashboard-metric-grid">
            <.link
              id="dashboard-draft-polls"
              navigate={~p"/admin/polls?status=draft"}
              class="card dashboard-metric"
            >
              <div>
                <div class="m-eyebrow">Drafts</div>
                <strong class="dashboard-metric-value">{@poll_counts.draft}</strong>
              </div>
              <span class="dashboard-metric-icon"><.icon name="hero-document-text" /></span>
            </.link>
            <.link
              id="dashboard-open-polls"
              navigate={~p"/admin/polls?status=open"}
              class="card dashboard-metric"
            >
              <div>
                <div class="m-eyebrow">Open</div>
                <strong class="dashboard-metric-value">{@poll_counts.open}</strong>
              </div>
              <span class="dashboard-metric-icon open"><.icon name="hero-clock" /></span>
            </.link>
            <.link
              id="dashboard-closed-polls"
              navigate={~p"/admin/polls?status=all_closed"}
              class="card dashboard-metric"
            >
              <div>
                <div class="m-eyebrow">Closed</div>
                <strong class="dashboard-metric-value">{@poll_counts.closed}</strong>
              </div>
              <span class="dashboard-metric-icon"><.icon name="hero-check-circle" /></span>
            </.link>
            <.link
              id="dashboard-unpublished-polls"
              navigate={~p"/admin/polls?status=closed"}
              class="card dashboard-metric"
            >
              <div>
                <div class="m-eyebrow">Unpublished</div>
                <strong class="dashboard-metric-value">{@poll_counts.unpublished}</strong>
              </div>
              <span class="dashboard-metric-icon attention"><.icon name="hero-eye" /></span>
            </.link>
          </div>
        </section>
      </section>
    </Layouts.app>
    """
  end

  defp load_dashboard(actor) do
    case Polly.Administration.Dashboard.load(actor) do
      {:ok, dashboard} -> dashboard
      {:error, :forbidden} -> %{poll_counts: nil, attention_items: nil}
    end
  end

  defp attention_title(%{kind: :missing_options, count: count}),
    do: count_title(count, "draft needs options", "drafts need options")

  defp attention_title(%{kind: :missing_electorate, count: count}),
    do: count_title(count, "draft needs members", "drafts need members")

  defp attention_title(%{kind: :unsent_invitations, count: count}),
    do:
      count_title(
        count,
        "open poll has no accepted deliveries",
        "open polls have no accepted deliveries"
      )

  defp attention_title(%{kind: :failed_deliveries, count: count}),
    do: count_title(count, "open poll has failed deliveries", "open polls have failed deliveries")

  defp attention_title(%{kind: :unpublished_results, count: count}),
    do: count_title(count, "result awaits publication", "results await publication")

  defp count_title(1, singular, _plural), do: "1 #{singular}"
  defp count_title(count, _singular, plural), do: "#{count} #{plural}"

  defp attention_description(:missing_options),
    do: "Add at least two active options before opening these polls."

  defp attention_description(:missing_electorate),
    do: "Include eligible members before these polls can open."

  defp attention_description(:unsent_invitations),
    do: "No invitation email has been accepted by the provider."

  defp attention_description(:failed_deliveries),
    do: "Some member invitation deliveries require review."

  defp attention_description(:unpublished_results),
    do: "Closed poll results are ready to review and publish."

  defp attention_link(:missing_options), do: "View drafts"
  defp attention_link(:missing_electorate), do: "View electorates"
  defp attention_link(:unsent_invitations), do: "View open polls"
  defp attention_link(:failed_deliveries), do: "View deliveries"
  defp attention_link(:unpublished_results), do: "Review results"

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
