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
     |> assign(:attention_visible?, dashboard.attention_items != nil)
     |> assign(:attention_empty?, dashboard.attention_items == [])
     |> assign(:active_polls_visible?, dashboard.active_polls != nil)
     |> assign(:active_polls_empty?, dashboard.active_polls == [])
     |> assign(:recent_activity_visible?, dashboard.recent_events != nil)
     |> assign(:recent_activity_empty?, dashboard.recent_events == [])
     |> assign(:account_health, dashboard.account_health)
     |> assign(:quick_actions, quick_actions(actor))
     |> stream_configure(:attention_items, dom_id: &"dashboard-attention-#{&1.kind}")
     |> stream(:attention_items, dashboard.attention_items || [])
     |> stream_configure(:active_polls, dom_id: &"dashboard-active-poll-#{&1.id}")
     |> stream(:active_polls, dashboard.active_polls || [])
     |> stream(:recent_events, dashboard.recent_events || [])}
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

        <section :if={@attention_visible?} id="dashboard-attention" class="dashboard-section">
          <h2 class="dashboard-section-heading">Action required</h2>
          <div
            id="dashboard-attention-items"
            class="dashboard-attention-grid"
            phx-update="stream"
          >
            <div
              :if={@attention_empty?}
              id="dashboard-attention-empty"
              class="card dashboard-attention-empty"
            >
              <span class="dashboard-attention-ok"><.icon name="hero-check-circle" /></span>
              <div>
                <strong>Nothing needs attention</strong>
                <p>Poll configuration and results are up to date.</p>
              </div>
            </div>
            <article
              :for={{id, item} <- @streams.attention_items}
              id={id}
              class={[
                "card",
                "dashboard-attention-card",
                item.kind in [:failed_deliveries, :integrity_issues] && "critical"
              ]}
            >
              <span class="dashboard-attention-icon">
                <.icon name="hero-exclamation-triangle" />
              </span>
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

        <section
          :if={@active_polls_visible?}
          id="dashboard-active-polls"
          class="dashboard-section card dashboard-panel"
        >
          <div class="dashboard-panel-heading">
            <h2 class="dashboard-section-heading">Active polls</h2>
            <.link
              :if={!@active_polls_empty?}
              navigate={~p"/admin/polls?status=open"}
              class="dashboard-card-link"
            >
              View all polls <.icon name="hero-arrow-right" />
            </.link>
          </div>
          <div
            :if={@active_polls_empty?}
            id="dashboard-active-polls-empty"
            class="dashboard-panel-empty"
          >
            No polls are currently open.
          </div>
          <div
            :if={!@active_polls_empty?}
            id="dashboard-active-poll-list"
            class="dashboard-active-poll-list"
            phx-update="stream"
          >
            <.link
              :for={{id, poll} <- @streams.active_polls}
              id={id}
              navigate={poll.destination}
              class="dashboard-active-poll-row"
            >
              <div>
                <h3>{poll.title}</h3>
                <span>{poll.participation_count} of {poll.eligible_count} votes</span>
                <span id={"active-poll-timing-#{poll.id}"} class="dashboard-active-poll-timing">
                  {PollyWeb.PollTiming.summary(poll.opened_at)}
                </span>
              </div>
              <div class="dashboard-turnout">
                <strong>{format_percentage(poll.turnout_percentage)} turnout</strong>
                <progress max="100" value={poll.turnout_percentage}>
                  {poll.turnout_percentage}%
                </progress>
              </div>
              <div class="dashboard-delivery-summary">{delivery_summary(poll)}</div>
              <span class="pill open"><span class="dotlive"></span>Open</span>
            </.link>
          </div>
        </section>

        <div
          :if={@recent_activity_visible? || @account_health != nil}
          class="dashboard-secondary-grid"
        >
          <section
            :if={@recent_activity_visible?}
            id="dashboard-recent-activity"
            class="dashboard-section card dashboard-panel"
          >
            <div class="dashboard-panel-heading">
              <h2 class="dashboard-section-heading">Recent activity</h2>
              <.link navigate={~p"/admin/audit"} class="dashboard-card-link">
                View audit trail <.icon name="hero-arrow-right" />
              </.link>
            </div>
            <div
              :if={@recent_activity_empty?}
              id="dashboard-recent-activity-empty"
              class="dashboard-panel-empty"
            >
              No administrator activity has been recorded yet.
            </div>
            <div id="dashboard-recent-events" phx-update="stream">
              <.link
                :for={{id, event} <- @streams.recent_events}
                id={id}
                navigate={~p"/admin/audit/#{event.id}"}
                class="dashboard-activity-row"
              >
                <span class="dashboard-activity-icon">
                  <.icon name="hero-document-text" />
                </span>
                <span class="dashboard-activity-copy">
                  <strong>{event.actor_label}</strong>
                  <span>{Polly.Audit.humanize(event)}</span>
                </span>
                <time datetime={DateTime.to_iso8601(event.occurred_at)}>
                  {format_datetime(event.occurred_at)}
                </time>
              </.link>
            </div>
          </section>

          <section
            :if={@account_health != nil}
            id="dashboard-account-health"
            class="dashboard-section card dashboard-panel"
          >
            <div class="dashboard-panel-heading">
              <h2 class="dashboard-section-heading">Account security</h2>
              <.link navigate={~p"/admin/administrators"} class="dashboard-card-link">
                Manage administrators <.icon name="hero-arrow-right" />
              </.link>
            </div>

            <div
              :if={@account_health.final_owner?}
              id="dashboard-final-owner-warning"
              class="dashboard-security-warning"
            >
              <span><.icon name="hero-exclamation-triangle" /></span>
              <div>
                <strong>Only one active owner remains</strong>
                <p>Add another owner to protect administrator access.</p>
              </div>
            </div>

            <div
              :if={@account_health.expiring_invitations > 0}
              id="dashboard-expiring-invitations-warning"
              class="dashboard-security-warning invitation"
            >
              <span><.icon name="hero-clock" /></span>
              <div>
                <strong>{expiring_invitation_warning(@account_health.expiring_invitations)}</strong>
                <p>Review or renew the invitations before they expire.</p>
              </div>
            </div>

            <dl class="dashboard-account-metrics">
              <div id="dashboard-active-owner-count">
                <dt>Active owners</dt>
                <dd>{@account_health.active_owners}</dd>
              </div>
              <div id="dashboard-disabled-account-count">
                <dt>Disabled accounts</dt>
                <dd>{@account_health.disabled_accounts}</dd>
              </div>
              <div id="dashboard-unconfirmed-account-count">
                <dt>Unconfirmed accounts</dt>
                <dd>{@account_health.unconfirmed_accounts}</dd>
              </div>
              <div id="dashboard-pending-administrator-invitation-count">
                <dt>Pending invitations</dt>
                <dd>{@account_health.pending_invitations}</dd>
              </div>
              <div
                id="dashboard-expiring-administrator-invitation-count"
                class={[
                  @account_health.expiring_invitations > 0 && "attention"
                ]}
              >
                <dt>Expiring within 48 hours</dt>
                <dd>{@account_health.expiring_invitations}</dd>
              </div>
            </dl>
          </section>
        </div>
      </section>
    </Layouts.app>
    """
  end

  defp load_dashboard(actor) do
    case Polly.Administration.Dashboard.load(actor) do
      {:ok, dashboard} ->
        dashboard

      {:error, :forbidden} ->
        %{
          poll_counts: nil,
          attention_items: nil,
          active_polls: nil,
          recent_events: nil,
          account_health: nil
        }
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

  defp attention_title(%{kind: :integrity_issues, count: count}),
    do: count_title(count, "poll has an integrity warning", "polls have integrity warnings")

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

  defp attention_description(:integrity_issues),
    do: "Participation and ballot totals differ. Review affected poll results before publishing."

  defp attention_link(:missing_options), do: "View drafts"
  defp attention_link(:missing_electorate), do: "View electorates"
  defp attention_link(:unsent_invitations), do: "View open polls"
  defp attention_link(:failed_deliveries), do: "View deliveries"
  defp attention_link(:unpublished_results), do: "Review results"
  defp attention_link(:integrity_issues), do: "Review polls"

  defp format_percentage(percentage), do: :erlang.float_to_binary(percentage, decimals: 1) <> "%"

  defp delivery_summary(%{failed_deliveries: failed}) when failed > 0,
    do: "#{failed} failed"

  defp delivery_summary(%{accepted_deliveries: accepted, pending_deliveries: pending})
       when accepted > 0 or pending > 0,
       do: "#{accepted} accepted · #{pending} pending"

  defp delivery_summary(_poll), do: "No deliveries"

  defp format_datetime(datetime), do: Calendar.strftime(datetime, "%b %d, %Y · %H:%M")

  defp expiring_invitation_warning(1), do: "1 administrator invitation expires within 48 hours"

  defp expiring_invitation_warning(count),
    do: "#{count} administrator invitations expire within 48 hours"

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
