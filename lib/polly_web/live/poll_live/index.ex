defmodule PollyWeb.PollLive.Index do
  use PollyWeb, :live_view

  require Ash.Query

  alias Polly.Polls.{Poll, SelectionRules}

  @page_size 25

  on_mount {PollyWeb.LiveUserAuth, {:require_any_permission, [:manage_polls, :view_results]}}

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Polls")
     |> assign(
       :manage_polls?,
       Polly.Accounts.Authorization.allowed?(socket.assigns.current_user, :manage_polls)
     )
     |> assign(:polls, [])
     |> assign(:polls_empty?, true)
     |> assign(:previous_cursor, nil)
     |> assign(:next_cursor, nil)}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    status_filter = status_filter(params)

    case list_polls(socket.assigns.current_user, params) do
      {:ok, page} ->
        {:noreply,
         socket
         |> assign(:polls, page.results)
         |> assign(:polls_empty?, page.results == [])
         |> assign(:status_filter, status_filter)
         |> assign(:previous_cursor, previous_cursor(page))
         |> assign(:next_cursor, next_cursor(page))}

      {:error, _error} ->
        {:noreply, push_patch(socket, to: ~p"/admin/polls")}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} active_nav={:polls}>
      <section id="polls-index">
        <div class="admin-titlebar">
          <div class="admin-h1">Polls</div>
          <.link
            :if={@manage_polls?}
            id="new-poll-link"
            navigate={~p"/admin/polls/new"}
            class="btn btn-coral"
          >
            <.icon name="hero-plus" class="size-4" /> New poll
          </.link>
        </div>
        <p class="admin-sub">Every poll owns its options, electorate, lifecycle, and results.</p>
        <div class="laneline" style="margin-bottom:20px;"></div>

        <nav id="poll-status-filters" class="detail-tabs" aria-label="Filter polls by status">
          <.link
            :for={{label, status} <- status_filters()}
            id={"poll-filter-#{status}"}
            patch={status_filter_path(status)}
            class={["phase-tab", @status_filter == status && "current"]}
          >
            {label}
          </.link>
        </nav>

        <div id="polls" class="poll-list">
          <div
            :if={@polls_empty?}
            id="polls-empty"
            class="empty-state"
          >
            <h2>{empty_title(@status_filter)}</h2>
            <p>{empty_message(@status_filter)}</p>
          </div>
          <article
            :for={poll <- @polls}
            id={"polls-#{poll.id}"}
            class="poll-card"
          >
            <.link
              navigate={poll_destination(poll, @manage_polls?)}
              class="poll-card-link"
            >
              <div class="poll-name">{poll.title}</div>
              <div id={"poll-selection-rules-#{poll.id}"} class="poll-meta">
                {SelectionRules.summary(poll)} · {poll.slug}
              </div>
            </.link>
            <span id={"poll-status-#{poll.id}"} class={status_class(poll)}>
              <span :if={poll.status == :open} class="dotlive"></span>
              {status_label(poll)}
            </span>

            <div class="poll-actions">
              <.link
                :if={@manage_polls?}
                id={"poll-options-#{poll.id}"}
                navigate={~p"/admin/polls/#{poll.id}/options"}
                class="btn btn-ghost btn-sm"
              >
                Options
              </.link>
              <.link
                :if={@manage_polls? && poll.status == :draft}
                id={"poll-edit-#{poll.id}"}
                navigate={~p"/admin/polls/#{poll.id}/edit"}
                class="btn btn-outline btn-sm"
              >
                Edit
              </.link>
              <.link
                :if={@manage_polls?}
                id={"poll-duplicate-#{poll.id}"}
                navigate={~p"/admin/polls/#{poll.id}/duplicate"}
                class="btn btn-outline btn-sm"
                aria-label={"Duplicate #{poll.title}"}
              >
                Duplicate
              </.link>
            </div>
          </article>
        </div>

        <nav
          :if={@previous_cursor || @next_cursor}
          id="poll-pagination"
          class="poll-actions"
          aria-label="Poll pages"
        >
          <.link
            :if={@previous_cursor}
            id="previous-polls-page"
            patch={pagination_path(@status_filter, :before, @previous_cursor)}
            class="btn btn-outline btn-sm"
          >
            Previous
          </.link>
          <.link
            :if={@next_cursor}
            id="next-polls-page"
            patch={pagination_path(@status_filter, :after, @next_cursor)}
            class="btn btn-outline btn-sm"
          >
            Next
          </.link>
        </nav>
      </section>
    </Layouts.app>
    """
  end

  defp list_polls(actor, params) do
    Poll
    |> Ash.Query.sort(updated_at: :desc, id: :desc)
    |> apply_status_filter(status_filter(params))
    |> Ash.read(actor: actor, page: page_options(params))
  end

  defp apply_status_filter(query, :all), do: query
  defp apply_status_filter(query, :draft), do: Ash.Query.filter(query, status == :draft)
  defp apply_status_filter(query, :open), do: Ash.Query.filter(query, status == :open)
  defp apply_status_filter(query, :all_closed), do: Ash.Query.filter(query, status == :closed)

  defp apply_status_filter(query, :closed),
    do: Ash.Query.filter(query, status == :closed and is_nil(results_published_at))

  defp apply_status_filter(query, :published),
    do: Ash.Query.filter(query, status == :closed and not is_nil(results_published_at))

  defp status_filter(%{"status" => "draft"}), do: :draft
  defp status_filter(%{"status" => "open"}), do: :open
  defp status_filter(%{"status" => "all_closed"}), do: :all_closed
  defp status_filter(%{"status" => "closed"}), do: :closed
  defp status_filter(%{"status" => "published"}), do: :published
  defp status_filter(_params), do: :all

  defp status_filters,
    do: [
      {"All", :all},
      {"Drafts", :draft},
      {"Open", :open},
      {"Closed", :closed},
      {"Published", :published}
    ]

  defp status_filter_path(:all), do: ~p"/admin/polls"
  defp status_filter_path(status), do: ~p"/admin/polls?status=#{status}"

  defp poll_destination(poll, true), do: ~p"/admin/polls/#{poll.id}/options"
  defp poll_destination(poll, false), do: ~p"/admin/polls/#{poll.id}/results"

  defp pagination_path(status, direction, cursor) do
    params = %{Atom.to_string(direction) => cursor}
    params = if status == :all, do: params, else: Map.put(params, "status", status)
    ~p"/admin/polls?#{params}"
  end

  defp page_options(%{"after" => cursor}) when is_binary(cursor) and cursor != "",
    do: [limit: @page_size, after: cursor]

  defp page_options(%{"before" => cursor}) when is_binary(cursor) and cursor != "",
    do: [limit: @page_size, before: cursor]

  defp page_options(_params), do: [limit: @page_size]

  defp previous_cursor(%Ash.Page.Keyset{results: []}), do: nil

  defp previous_cursor(%Ash.Page.Keyset{results: results, after: after_cursor})
       when not is_nil(after_cursor),
       do: keyset(List.first(results))

  defp previous_cursor(%Ash.Page.Keyset{results: results, before: before_cursor, more?: true})
       when not is_nil(before_cursor),
       do: keyset(List.first(results))

  defp previous_cursor(_page), do: nil

  defp next_cursor(%Ash.Page.Keyset{results: []}), do: nil

  defp next_cursor(%Ash.Page.Keyset{results: results, before: before_cursor})
       when not is_nil(before_cursor),
       do: keyset(List.last(results))

  defp next_cursor(%Ash.Page.Keyset{results: results, more?: true}),
    do: keyset(List.last(results))

  defp next_cursor(_page), do: nil

  defp keyset(record), do: record.__metadata__.keyset

  defp empty_title(:all), do: "No polls yet"
  defp empty_title(:draft), do: "No draft polls"
  defp empty_title(:open), do: "No open polls"
  defp empty_title(:all_closed), do: "No closed polls"
  defp empty_title(:closed), do: "No closed polls"
  defp empty_title(:published), do: "No published polls"

  defp empty_message(:all), do: "Create the first draft to begin configuring options."
  defp empty_message(_status), do: "Choose another status to view more polls."

  defp status_label(%Poll{status: :closed, results_published_at: published_at})
       when not is_nil(published_at),
       do: "Published"

  defp status_label(%Poll{status: status}), do: status |> to_string() |> String.capitalize()

  defp status_class(%Poll{status: :closed, results_published_at: published_at})
       when not is_nil(published_at),
       do: "pill published"

  defp status_class(%Poll{status: :draft}), do: "pill draft"
  defp status_class(%Poll{status: :open}), do: "pill open"
  defp status_class(%Poll{status: :closed}), do: "pill closed"
end
