defmodule PollyWeb.PollLive.Index do
  use PollyWeb, :live_view

  alias Polly.Polls.Poll

  @page_size 25

  on_mount {PollyWeb.LiveUserAuth, :live_user_required}

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Polls")
     |> assign(:polls, [])
     |> assign(:polls_empty?, true)
     |> assign(:previous_cursor, nil)
     |> assign(:next_cursor, nil)}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    case list_polls(socket.assigns.current_user, params) do
      {:ok, page} ->
        {:noreply,
         socket
         |> assign(:polls, page.results)
         |> assign(:polls_empty?, page.results == [])
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
          <.link id="new-poll-link" navigate={~p"/admin/polls/new"} class="btn btn-coral">
            <.icon name="hero-plus" class="size-4" /> New poll
          </.link>
        </div>
        <p class="admin-sub">Every poll owns its options, electorate, lifecycle, and results.</p>
        <div class="laneline" style="margin-bottom:20px;"></div>

        <div id="polls" class="poll-list">
          <div
            :if={@polls_empty?}
            id="polls-empty"
            class="empty-state"
          >
            <h2>No polls yet</h2>
            <p>Create the first draft to begin configuring options.</p>
          </div>
          <article
            :for={poll <- @polls}
            id={"polls-#{poll.id}"}
            class="poll-card"
          >
            <.link
              navigate={~p"/admin/polls/#{poll.id}/options"}
              class="poll-card-link"
            >
              <div class="poll-name">{poll.title}</div>
              <div class="poll-meta">Single choice · {poll.slug}</div>
            </.link>
            <span class={status_class(poll.status)}>
              <span :if={poll.status == :open} class="dotlive"></span>
              {status_label(poll.status)}
            </span>
            <div class="turnout">
              <div class="turnout-num">
                {if(poll.status == :draft, do: "Options ready to configure", else: "Poll configured")}
              </div>
              <div class="turnout-track">
                <div class="turnout-fill" style="width:0%"></div>
              </div>
            </div>
            <div class="poll-actions">
              <.link
                id={"poll-options-#{poll.id}"}
                navigate={~p"/admin/polls/#{poll.id}/options"}
                class="btn btn-ghost btn-sm"
              >
                Options
              </.link>
              <.link
                :if={poll.status == :draft}
                id={"poll-edit-#{poll.id}"}
                navigate={~p"/admin/polls/#{poll.id}/edit"}
                class="btn btn-outline btn-sm"
              >
                Edit
              </.link>
              <.link
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
            patch={~p"/admin/polls?before=#{@previous_cursor}"}
            class="btn btn-outline btn-sm"
          >
            Previous
          </.link>
          <.link
            :if={@next_cursor}
            id="next-polls-page"
            patch={~p"/admin/polls?after=#{@next_cursor}"}
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
    |> Ash.read(actor: actor, page: page_options(params))
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

  defp status_label(status), do: status |> to_string() |> String.capitalize()

  defp status_class(:draft), do: "pill draft"
  defp status_class(:open), do: "pill open"
  defp status_class(:closed), do: "pill closed"
end
