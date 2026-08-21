defmodule PollyWeb.AdminLive do
  use PollyWeb, :live_view

  on_mount {PollyWeb.LiveUserAuth, :live_user_required}

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, :page_title, "Administration")}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <section id="admin-overview" class="space-y-6">
        <div>
          <p class="text-sm font-semibold uppercase tracking-wide text-primary">Polly</p>
          <h1 class="mt-2 text-3xl font-bold">Administration</h1>
          <p class="mt-3 text-base-content/70">
            The authentication foundation is ready. Poll and member management arrive in the
            next delivery phases.
          </p>
        </div>

        <div id="phase-zero-status" class="rounded-box border border-base-300 bg-base-100 p-6">
          <h2 class="text-lg font-semibold">Phase 0 complete</h2>
          <p class="mt-2 text-sm text-base-content/70">
            Administrator access is protected and the first-release product decisions are
            recorded.
          </p>
        </div>
      </section>
    </Layouts.app>
    """
  end
end
