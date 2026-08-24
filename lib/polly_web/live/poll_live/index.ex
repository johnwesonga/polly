defmodule PollyWeb.PollLive.Index do
  use PollyWeb, :live_view

  alias Polly.Polls.Poll

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
      </section>
    </Layouts.app>
    """
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
end
