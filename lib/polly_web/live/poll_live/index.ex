defmodule PollyWeb.PollLive.Index do
  use PollyWeb, :live_view

  alias Polly.Polls.{Duplicator, Poll}

  on_mount {PollyWeb.LiveUserAuth, :live_user_required}

  @impl true
  def mount(_params, _session, socket) do
    polls = list_polls(socket.assigns.current_user)

    {:ok,
     socket
     |> assign(:page_title, "Polls")
     |> assign(:polls_empty?, polls == [])
     |> stream(:polls, polls)}
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

        <div id="polls" phx-update="stream" class="poll-list">
          <div
            id="polls-empty"
            class="empty-state hidden only:block"
          >
            <h2>No polls yet</h2>
            <p>Create the first draft to begin configuring options.</p>
          </div>
          <article
            :for={{id, poll} <- @streams.polls}
            id={id}
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
              <button
                id={"poll-duplicate-#{poll.id}"}
                type="button"
                phx-click="duplicate"
                phx-value-id={poll.id}
                data-confirm={
                  "Duplicate #{poll.title}? Only its title, description, and selection mode will be copied into a new draft."
                }
                class="btn btn-outline btn-sm"
                aria-label={"Duplicate #{poll.title}"}
              >
                Duplicate
              </button>
            </div>
          </article>
        </div>
      </section>
    </Layouts.app>
    """
  end

  @impl true
  def handle_event("duplicate", %{"id" => id}, socket) do
    case Duplicator.duplicate(id, socket.assigns.current_user) do
      {:ok, %{poll: duplicate, source_title: source_title}} ->
        {:noreply,
         socket
         |> put_flash(:info, "Draft duplicated from #{source_title}")
         |> push_navigate(to: ~p"/admin/polls/#{duplicate.id}/edit")}

      {:error, error} ->
        {:noreply, put_flash(socket, :error, duplicate_error(error))}
    end
  end

  defp list_polls(actor) do
    Poll
    |> Ash.Query.sort(updated_at: :desc)
    |> Ash.read!(actor: actor)
  end

  defp status_label(status), do: status |> to_string() |> String.capitalize()

  defp status_class(:draft), do: "pill draft"
  defp status_class(:open), do: "pill open"
  defp status_class(:closed), do: "pill closed"

  defp duplicate_error(:actor_required), do: "You must sign in to duplicate a poll"
  defp duplicate_error(:slug_generation_exhausted), do: "Could not generate a unique poll slug"
  defp duplicate_error(error), do: Exception.message(error)
end
