defmodule PollyWeb.PollLive.Duplicate do
  use PollyWeb, :live_view

  alias Polly.Polls.Duplicator

  on_mount {PollyWeb.LiveUserAuth, {:require_permission, :manage_polls}}

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    preview = load_preview!(id, socket.assigns.current_user)
    choices = %{copy_options?: true, copy_electorate?: false}

    {:ok,
     socket
     |> assign(:page_title, "Duplicate #{preview.source.title}")
     |> assign(:preview, preview)
     |> assign(:choices, choices)
     |> assign_form(choices)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} active_nav={:polls}>
      <section id="poll-duplicate-page">
        <div class="breadcrumb">
          <.link navigate={~p"/admin/polls"}>Polls</.link><span>/</span>
          <span>Duplicate {@preview.source.title}</span>
        </div>

        <div class="detail-header">
          <div>
            <div class="admin-h1">DUPLICATE POLL</div>
            <p class="admin-sub" style="margin:4px 0 0;">
              Create an independent draft from reusable configuration.
            </p>
          </div>
          <span class={"pill #{@preview.source.status}"}>Source: {@preview.source.status}</span>
        </div>
        <div class="laneline" style="margin:14px 0 20px;"></div>

        <.form
          for={@form}
          id="duplicate-poll-form"
          phx-change="change"
          phx-submit="duplicate"
          class="duplicate-layout"
        >
          <div class="card card-pad duplicate-options-card">
            <h3>Choose what to copy</h3>

            <div class="duplicate-choice locked-choice">
              <div class="checkbox on" aria-hidden="true">
                <.icon name="hero-check" class="size-3" />
              </div>
              <div>
                <strong>Poll details</strong>
                <p>Title, description, and selection mode are always copied.</p>
              </div>
            </div>

            <div class="duplicate-choice">
              <.input
                field={@form[:copy_options]}
                type="checkbox"
                label="Copy active options"
                class="checkbox checkbox-sm"
              />
              <p>
                {@preview.active_option_count} active option{plural(@preview.active_option_count)} available. Labels and positions will be copied with new IDs.
              </p>
            </div>

            <div class="duplicate-choice">
              <.input
                field={@form[:copy_electorate]}
                type="checkbox"
                label="Copy active electorate members"
                class="checkbox checkbox-sm"
              />
              <p>
                {@preview.active_member_count} active member{plural(@preview.active_member_count)} available. Each copied member receives a new private access grant.
              </p>
            </div>

            <div
              :if={@choices.copy_electorate? && @preview.skipped_member_count > 0}
              id="skipped-members-warning"
              class="callout amber duplicate-warning"
            >
              <.icon name="hero-exclamation-triangle" class="size-5" />
              <span>
                {@preview.skipped_member_count} inactive member{plural(@preview.skipped_member_count)} will be skipped.
              </span>
            </div>
          </div>

          <aside class="card card-pad duplicate-preview-card">
            <h3>New draft preview</h3>
            <dl class="duplicate-summary">
              <div>
                <dt>Source</dt>
                <dd>{@preview.source.title}</dd>
              </div>
              <div>
                <dt>New title</dt>
                <dd>{@preview.proposed_title}</dd>
              </div>
              <div>
                <dt>New slug</dt>
                <dd class="mono">{@preview.proposed_slug}</dd>
              </div>
              <div>
                <dt>Options</dt>
                <dd id="preview-option-count">{selected_option_count(assigns)}</dd>
              </div>
              <div>
                <dt>Members</dt>
                <dd id="preview-member-count">{selected_member_count(assigns)}</dd>
              </div>
            </dl>

            <div class="callout amber duplication-boundary-warning">
              <.icon name="hero-shield-exclamation" class="size-5" />
              <span>
                Ballots, results, lifecycle state, and existing access links are never copied.
              </span>
            </div>

            <button id="confirm-duplicate-button" type="submit" class="btn btn-coral duplicate-submit">
              Create duplicate draft
            </button>
            <.link navigate={~p"/admin/polls"} class="btn btn-ghost duplicate-cancel">
              Cancel
            </.link>
          </aside>
        </.form>
      </section>
    </Layouts.app>
    """
  end

  @impl true
  def handle_event("change", %{"duplicate" => params}, socket) do
    choices = choices_from_params(params)
    {:noreply, socket |> assign(:choices, choices) |> assign_form(choices)}
  end

  def handle_event("duplicate", %{"duplicate" => params}, socket) do
    choices = choices_from_params(params)

    case Duplicator.duplicate(
           socket.assigns.preview.source.id,
           choices,
           socket.assigns.current_user
         ) do
      {:ok, result} ->
        {:noreply,
         socket
         |> put_flash(:info, success_message(result))
         |> push_navigate(to: ~p"/admin/polls/#{result.poll.id}/edit")}

      {:error, error} ->
        {:noreply, put_flash(socket, :error, duplicate_error(error))}
    end
  end

  defp load_preview!(source_id, actor) do
    case Duplicator.preview(source_id, actor) do
      {:ok, preview} -> preview
      {:error, error} -> raise error
    end
  end

  defp assign_form(socket, choices) do
    params = %{
      "copy_options" => to_string(choices.copy_options?),
      "copy_electorate" => to_string(choices.copy_electorate?)
    }

    assign(socket, :form, to_form(params, as: :duplicate))
  end

  defp choices_from_params(params) do
    %{
      copy_options?: params["copy_options"] == "true",
      copy_electorate?: params["copy_electorate"] == "true"
    }
  end

  defp selected_option_count(assigns) do
    if assigns.choices.copy_options?, do: assigns.preview.active_option_count, else: 0
  end

  defp selected_member_count(assigns) do
    if assigns.choices.copy_electorate?, do: assigns.preview.active_member_count, else: 0
  end

  defp success_message(result) do
    "Draft duplicated from #{result.source_title}: #{result.options_copied} options and " <>
      "#{result.members_copied} members copied"
  end

  defp duplicate_error(:actor_required), do: "You must sign in to duplicate a poll"
  defp duplicate_error(:slug_generation_exhausted), do: "Could not generate a unique poll slug"
  defp duplicate_error(error), do: Exception.message(error)

  defp plural(1), do: ""
  defp plural(_count), do: "s"
end
