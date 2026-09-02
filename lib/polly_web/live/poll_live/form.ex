defmodule PollyWeb.PollLive.Form do
  @moduledoc """
  Creates and edits draft poll configuration.

  The form captures poll details and single- or multiple-choice selection
  rules. The underlying Ash actions enforce that configuration changes remain
  limited to draft polls.
  """

  use PollyWeb, :live_view

  alias Polly.Polls.{Poll}

  on_mount {PollyWeb.LiveUserAuth, {:require_permission, :manage_polls}}

  @impl true
  def mount(params, _session, socket) do
    poll = load_poll(params, socket.assigns.current_user)

    {:ok,
     socket
     |> assign(:page_title, if(poll, do: "Edit poll", else: "New poll"))
     |> assign(:poll, poll)
     |> assign_form()}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} active_nav={:polls}>
      <section id="poll-form-page">
        <div class="breadcrumb">
          <.link navigate={~p"/admin/polls"}>Polls</.link><span>/</span><span>{@page_title}</span>
        </div>
        <div class="detail-header">
          <div>
            <div class="admin-h1">{String.upcase(@page_title)}</div>
            <p class="admin-sub" style="margin:4px 0 0;">
              Configure the poll’s public title and supporting context.
            </p>
          </div>
          <span class="pill draft">Draft</span>
        </div>
        <div class="laneline" style="margin:14px 0 20px;"></div>

        <.form
          for={@form}
          id="poll-form"
          phx-change="validate"
          phx-submit="save"
          class="card card-pad form-card space-y-5"
        >
          <.input field={@form[:title]} type="text" label="Title" placeholder="2027 Team Theme" />
          <.input
            field={@form[:description]}
            type="textarea"
            label="Description"
            placeholder="Explain what members are choosing."
          />
          <fieldset id="poll-selection-rules" class="poll-selection-rules">
            <legend>Selection rules</legend>
            <p class="field-help">
              Choose how many distinct options each member may select.
            </p>
            <.input
              field={@form[:selection_mode]}
              type="select"
              label="Selection mode"
              options={[
                {"Single choice — choose exactly one", :single},
                {"Multiple choice — choose more than one", :multiple}
              ]}
            />
            <div
              :if={multiple_choice?(@form)}
              id="multiple-choice-limits"
              class="poll-selection-limit-grid"
            >
              <.input
                field={@form[:minimum_selections]}
                type="number"
                label="Minimum choices"
                min="1"
                step="1"
              />
              <.input
                field={@form[:maximum_selections]}
                type="number"
                label="Maximum choices"
                min="1"
                step="1"
              />
            </div>
            <p :if={!multiple_choice?(@form)} id="single-choice-summary" class="field-help">
              Members choose exactly one option.
            </p>
          </fieldset>
          <p :if={!@poll} class="text-sm text-base-content/60">
            A stable URL slug will be generated from the title.
          </p>
          <div class="form-actions">
            <.link navigate={~p"/admin/polls"} class="btn btn-ghost">Cancel</.link>
            <button id="save-poll-button" type="submit" class="btn btn-coral">
              {if(@poll, do: "Save changes", else: "Create draft")}
            </button>
          </div>
        </.form>
      </section>
    </Layouts.app>
    """
  end

  @impl true
  def handle_event("validate", %{"poll" => params}, socket) do
    params = normalize_selection_params(params)
    {:noreply, assign(socket, :form, AshPhoenix.Form.validate(socket.assigns.form, params))}
  end

  def handle_event("save", %{"poll" => params}, socket) do
    params = normalize_selection_params(params)

    case AshPhoenix.Form.submit(socket.assigns.form, params: params) do
      {:ok, poll} ->
        {:noreply,
         socket
         |> put_flash(:info, if(socket.assigns.poll, do: "Poll updated", else: "Draft created"))
         |> push_navigate(to: ~p"/admin/polls/#{poll.id}/options")}

      {:error, form} ->
        {:noreply, assign(socket, :form, form)}
    end
  end

  defp load_poll(%{"id" => id}, actor), do: Ash.get!(Poll, id, actor: actor)
  defp load_poll(_params, _actor), do: nil

  defp assign_form(%{assigns: %{poll: nil}} = socket) do
    form =
      AshPhoenix.Form.for_create(Poll, :create_draft,
        as: "poll",
        actor: socket.assigns.current_user
      )

    assign(socket, :form, to_form(form))
  end

  defp assign_form(socket) do
    form =
      AshPhoenix.Form.for_update(socket.assigns.poll, :update_draft,
        as: "poll",
        actor: socket.assigns.current_user
      )

    assign(socket, :form, to_form(form))
  end

  defp normalize_selection_params(%{"selection_mode" => "single"} = params) do
    params
    |> Map.put("minimum_selections", "1")
    |> Map.put("maximum_selections", "1")
  end

  defp normalize_selection_params(params), do: params

  defp multiple_choice?(form), do: to_string(form[:selection_mode].value) == "multiple"
end
