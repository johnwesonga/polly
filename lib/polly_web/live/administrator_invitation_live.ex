defmodule PollyWeb.AdministratorInvitationLive do
  @moduledoc "Public recipient-controlled administrator account setup."

  use PollyWeb, :live_view

  alias Polly.Accounts.AdministratorInvitations

  @impl true
  def mount(%{"id" => id, "token" => token}, _session, socket) do
    case AdministratorInvitations.verify(id, token) do
      {:ok, invitation} ->
        form = to_form(%{"password" => "", "password_confirmation" => ""}, as: :setup)

        {:ok,
         assign(socket,
           invitation: invitation,
           token: token,
           form: form,
           page_title: "Set up account"
         )}

      {:error, _reason} ->
        {:ok,
         assign(socket,
           invitation: nil,
           token: nil,
           form: nil,
           page_title: "Invitation unavailable"
         )}
    end
  end

  @impl true
  def handle_event("accept-invitation", %{"setup" => params}, socket) do
    case AdministratorInvitations.accept(
           socket.assigns.invitation.id,
           socket.assigns.token,
           params["password"],
           params["password_confirmation"]
         ) do
      {:ok, _user} ->
        {:noreply,
         socket
         |> put_flash(:info, "Your account is ready. Sign in to continue.")
         |> push_navigate(to: ~p"/sign-in")}

      {:error, :invalid_password} ->
        {:noreply,
         socket
         |> assign(:form, to_form(params, as: :setup))
         |> put_flash(:error, "Use matching passwords with at least eight characters.")}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "This invitation is no longer valid.")}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <section id="administrator-invitation-setup" class="form-card card card-pad">
        <%= if @invitation do %>
          <div class="m-eyebrow">Administrator invitation</div>
          <h1 class="admin-h1">Set up your account</h1>
          <p class="admin-sub">
            Join Touchpad as <strong>{role_label(@invitation.role)}</strong>
            using <strong>{@invitation.email}</strong>.
          </p>
          <.form for={@form} id="administrator-invitation-setup-form" phx-submit="accept-invitation">
            <.input field={@form[:password]} type="password" label="Password" required />
            <.input
              field={@form[:password_confirmation]}
              type="password"
              label="Confirm password"
              required
            />
            <div class="form-actions">
              <button id="accept-administrator-invitation" class="btn btn-coral" type="submit">
                Create account
              </button>
            </div>
          </.form>
        <% else %>
          <div class="m-eyebrow">Administrator invitation</div>
          <h1 class="admin-h1">Invitation unavailable</h1>
          <p class="admin-sub">This invitation is invalid, expired, or has already been used.</p>
          <.link navigate={~p"/sign-in"} class="btn btn-ghost">Return to sign in</.link>
        <% end %>
      </section>
    </Layouts.app>
    """
  end

  defp role_label(role), do: role |> to_string() |> String.capitalize()
end
