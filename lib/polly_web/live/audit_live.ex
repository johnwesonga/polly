defmodule PollyWeb.AuditLive do
  use PollyWeb, :live_view

  alias Polly.Audit
  alias Polly.Audit.Event

  on_mount {PollyWeb.LiveUserAuth, :live_user_required}

  @impl true
  def mount(params, _session, socket) do
    actor = socket.assigns.current_user
    events = list_events(actor)
    selected_event = load_selected_event(params, actor)

    {:ok,
     socket
     |> assign(:page_title, "Audit trail")
     |> assign(:events_empty?, events == [])
     |> assign(:selected_event, selected_event)
     |> stream(:audit_events, events)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} active_nav={:audit}>
      <section id="audit-trail-page">
        <div class="admin-titlebar">
          <div>
            <div class="admin-h1">Audit trail</div>
            <p class="admin-sub">Append-only history of consequential administrator actions.</p>
          </div>
        </div>
        <div class="laneline" style="margin-bottom:20px;"></div>

        <div class="detail-grid">
          <div class="card card-pad">
            <div id="audit-events" phx-update="stream">
              <div id="audit-events-empty" class="empty-state hidden only:block">
                <h2>No audit events yet</h2>
                <p>Critical poll administration actions will appear here.</p>
              </div>
              <article
                :for={{id, event} <- @streams.audit_events}
                id={id}
                class="member-row"
              >
                <div class="min-w-0 flex-1">
                  <strong>{event.actor_label} {Audit.humanize(event)}</strong>
                  <div class="poll-meta">
                    <time datetime={DateTime.to_iso8601(event.occurred_at)}>
                      {format_datetime(event.occurred_at)}
                    </time>
                    · {event.target_type} · {event.source}
                  </div>
                </div>
                <.link
                  id={"view-audit-event-#{event.id}"}
                  navigate={~p"/admin/audit/#{event.id}"}
                  class="btn btn-outline btn-sm"
                >
                  Details
                </.link>
              </article>
            </div>
          </div>

          <aside id="audit-event-detail" class="card card-pad" style="height:fit-content;">
            <%= if @selected_event do %>
              <div class="flex items-center justify-between gap-3">
                <h3>Event details</h3>
                <.link navigate={~p"/admin/audit"} class="btn btn-ghost btn-sm">Close</.link>
              </div>
              <dl class="duplicate-summary">
                <div>
                  <dt>Event</dt>
                  <dd>{@selected_event.action}</dd>
                </div>
                <div>
                  <dt>Occurred</dt>
                  <dd>{format_datetime(@selected_event.occurred_at)}</dd>
                </div>
                <div>
                  <dt>Actor</dt>
                  <dd>{@selected_event.actor_label}</dd>
                </div>
                <div>
                  <dt>Actor ID</dt>
                  <dd>{@selected_event.actor_id}</dd>
                </div>
                <div>
                  <dt>Target</dt>
                  <dd>{@selected_event.target_label}</dd>
                </div>
                <div>
                  <dt>Target ID</dt>
                  <dd>{@selected_event.target_id || "—"}</dd>
                </div>
                <div>
                  <dt>Poll ID</dt>
                  <dd>{@selected_event.poll_id || "—"}</dd>
                </div>
                <div>
                  <dt>Source</dt>
                  <dd>{@selected_event.source}</dd>
                </div>
                <div>
                  <dt>Request ID</dt>
                  <dd>{@selected_event.request_id || "—"}</dd>
                </div>
              </dl>

              <h3>Metadata</h3>
              <dl id="audit-event-metadata" class="duplicate-summary">
                <div :for={{key, value} <- sorted_metadata(@selected_event.metadata)}>
                  <dt>{humanize_key(key)}</dt>
                  <dd>{format_metadata_value(value)}</dd>
                </div>
                <div :if={map_size(@selected_event.metadata) == 0}>
                  <dd>No additional metadata.</dd>
                </div>
              </dl>
            <% else %>
              <h3>Event details</h3>
              <p class="admin-sub">Select an event to inspect its safe structured metadata.</p>
            <% end %>
          </aside>
        </div>
      </section>
    </Layouts.app>
    """
  end

  defp list_events(actor) do
    Event
    |> Ash.Query.sort(occurred_at: :desc, id: :desc)
    |> Ash.Query.limit(100)
    |> Ash.read!(actor: actor)
  end

  defp load_selected_event(%{"id" => id}, actor), do: Ash.get!(Event, id, actor: actor)
  defp load_selected_event(_params, _actor), do: nil

  defp sorted_metadata(metadata), do: Enum.sort_by(metadata, fn {key, _value} -> key end)

  defp humanize_key(key),
    do: key |> String.replace("_", " ") |> String.capitalize()

  defp format_metadata_value(value) when is_list(value), do: Enum.join(value, ", ")
  defp format_metadata_value(value), do: to_string(value)

  defp format_datetime(datetime) do
    Calendar.strftime(datetime, "%Y-%m-%d %H:%M:%S UTC")
  end
end
