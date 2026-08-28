defmodule PollyWeb.AuditLive do
  use PollyWeb, :live_view

  require Ash.Query

  alias Polly.Audit
  alias Polly.Audit.Event
  alias Polly.Polls.Poll

  on_mount {PollyWeb.LiveUserAuth, {:require_permission, :view_audit}}

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Audit trail")
     |> assign(:selected_event, nil)
     |> assign(:event_page, nil)
     |> assign(:event_count, 0)
     |> assign(:more_events?, false)
     |> assign(:filters, %{})
     |> assign(:actor_options, actor_options(socket.assigns.current_user))
     |> assign(:poll_options, poll_options(socket.assigns.current_user))
     |> assign(:filter_form, to_form(%{}, as: :filters))
     |> stream(:audit_events, [])}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    filters = filter_params(params)
    selected_event = load_selected_event(params, socket.assigns.current_user)

    if socket.assigns.event_page && socket.assigns.filters == filters do
      {:noreply, assign(socket, :selected_event, selected_event)}
    else
      page = list_events(socket.assigns.current_user, filters)

      {:noreply,
       socket
       |> assign(:filters, filters)
       |> assign(:filter_form, to_form(filters, as: :filters))
       |> assign(:selected_event, selected_event)
       |> assign_page(page)
       |> stream(:audit_events, page.results, reset: true)}
    end
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

        <.form
          for={@filter_form}
          id="audit-filters"
          phx-change="filter"
          class="card card-pad grid gap-3 md:grid-cols-3"
        >
          <.input
            field={@filter_form[:category]}
            type="select"
            label="Action category"
            options={[
              {"All categories", ""},
              {"Members", "member"},
              {"Polls", "poll"},
              {"Options", "poll_option"},
              {"Electorate", "poll_electorate"},
              {"Access grants", "poll_access_grant"}
            ]}
          />
          <.input
            field={@filter_form[:actor_id]}
            type="select"
            label="Actor"
            options={[{"All actors", ""} | @actor_options]}
          />
          <.input
            field={@filter_form[:target_type]}
            type="select"
            label="Target type"
            options={[
              {"All targets", ""},
              {"Poll", "poll"},
              {"Member", "member"},
              {"Poll option", "poll_option"},
              {"Member import", "member_import"}
            ]}
          />
          <.input
            field={@filter_form[:poll_id]}
            type="select"
            label="Poll"
            options={[{"All polls", ""} | @poll_options]}
          />
          <.input field={@filter_form[:date_from]} type="date" label="From date" />
          <.input field={@filter_form[:date_to]} type="date" label="Through date" />
        </.form>

        <div id="audit-event-count" class="poll-meta" style="margin:12px 0;">
          {@event_count} matching events
        </div>

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
                  patch={~p"/admin/audit/#{event.id}?#{@filters}"}
                  class="btn btn-outline btn-sm"
                >
                  Details
                </.link>
              </article>
            </div>
            <button
              :if={@more_events?}
              id="load-more-audit-events"
              type="button"
              phx-click="load-more"
              class="btn btn-outline mt-4"
            >
              Load more
            </button>
          </div>

          <aside id="audit-event-detail" class="card card-pad" style="height:fit-content;">
            <%= if @selected_event do %>
              <div class="flex items-center justify-between gap-3">
                <h3>Event details</h3>
                <.link patch={~p"/admin/audit?#{@filters}"} class="btn btn-ghost btn-sm">
                  Close
                </.link>
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

  @impl true
  def handle_event("filter", %{"filters" => filters}, socket) do
    filters = Map.reject(filters, fn {_key, value} -> value == "" end)
    {:noreply, push_patch(socket, to: ~p"/admin/audit?#{filters}")}
  end

  def handle_event("load-more", _params, socket) do
    page = Ash.page!(socket.assigns.event_page, :next)

    {:noreply,
     socket
     |> assign_page(page)
     |> stream(:audit_events, page.results)}
  end

  defp list_events(actor, filters) do
    Event
    |> Ash.Query.sort(occurred_at: :desc, id: :desc)
    |> apply_filters(filters)
    |> Ash.read!(actor: actor, page: [limit: 25, count: true])
  end

  defp apply_filters(query, filters) do
    Enum.reduce(filters, query, fn
      {"actor_id", actor_id}, query -> filter_uuid(query, :actor_id, actor_id)
      {"target_type", target_type}, query -> Ash.Query.filter(query, target_type == ^target_type)
      {"poll_id", poll_id}, query -> filter_uuid(query, :poll_id, poll_id)
      {"category", category}, query -> filter_category(query, category)
      {"date_from", value}, query -> filter_from_date(query, value)
      {"date_to", value}, query -> filter_to_date(query, value)
      {_unknown, _value}, query -> query
    end)
  end

  defp filter_category(query, category) do
    prefixes = if category == "member", do: ["member.", "member_import."], else: [category <> "."]

    actions =
      Enum.filter(
        Audit.actions(),
        &Enum.any?(prefixes, fn prefix -> String.starts_with?(&1, prefix) end)
      )

    Ash.Query.filter(query, action in ^actions)
  end

  defp filter_uuid(query, field, value) do
    case Ecto.UUID.cast(value) do
      {:ok, uuid} when field == :actor_id -> Ash.Query.filter(query, actor_id == ^uuid)
      {:ok, uuid} when field == :poll_id -> Ash.Query.filter(query, poll_id == ^uuid)
      :error -> query
    end
  end

  defp filter_from_date(query, value) do
    case Date.from_iso8601(value) do
      {:ok, date} ->
        Ash.Query.filter(query, occurred_at >= ^DateTime.new!(date, ~T[00:00:00], "Etc/UTC"))

      _error ->
        query
    end
  end

  defp filter_to_date(query, value) do
    case Date.from_iso8601(value) do
      {:ok, date} ->
        exclusive_end = date |> Date.add(1) |> DateTime.new!(~T[00:00:00], "Etc/UTC")
        Ash.Query.filter(query, occurred_at < ^exclusive_end)

      _error ->
        query
    end
  end

  defp assign_page(socket, page) do
    assign(socket,
      event_page: page,
      event_count: page.count || 0,
      more_events?: page.more?
    )
  end

  defp filter_params(params) do
    Map.take(params, ["actor_id", "category", "target_type", "poll_id", "date_from", "date_to"])
  end

  defp actor_options(actor) do
    Audit.actor_options(actor)
  end

  defp poll_options(actor) do
    Poll
    |> Ash.Query.sort(title: :asc)
    |> Ash.read!(actor: actor)
    |> Enum.map(&{&1.title, &1.id})
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
