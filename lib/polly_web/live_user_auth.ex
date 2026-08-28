defmodule PollyWeb.LiveUserAuth do
  @moduledoc """
  Helpers for authenticating users in LiveViews.
  """

  import Phoenix.Component
  import Phoenix.LiveView, only: [attach_hook: 4, put_flash: 3, redirect: 2]
  use PollyWeb, :verified_routes

  alias Polly.Accounts.Administrators
  alias Polly.Accounts.Authorization

  # This is used for nested liveviews to fetch the current user.
  # To use, place the following at the top of that liveview:
  # on_mount {PollyWeb.LiveUserAuth, :current_user}
  def on_mount(:current_user, _params, session, socket) do
    {:cont, AshAuthentication.Phoenix.LiveSession.assign_new_resources(socket, session)}
  end

  def on_mount(:live_user_optional, _params, _session, socket) do
    current_user = socket.assigns[:current_user]

    {:cont,
     socket
     |> assign(:current_user, current_user)
     |> assign(:current_scope, current_scope(current_user))}
  end

  def on_mount(:live_user_required, _params, _session, socket) do
    case socket.assigns[:current_user] do
      %{status: :active} = user ->
        socket =
          socket
          |> assign(:current_scope, current_scope(user))
          |> attach_hook(:active_administrator, :handle_event, &ensure_active/3)

        {:cont, socket}

      _ ->
        {:halt, redirect(socket, to: ~p"/sign-in")}
    end
  end

  def on_mount({:require_permission, permission}, _params, _session, socket) do
    require_permissions(socket, [permission])
  end

  def on_mount({:require_any_permission, permissions}, _params, _session, socket) do
    require_permissions(socket, permissions)
  end

  def on_mount(:live_no_user, _params, _session, socket) do
    if socket.assigns[:current_user] do
      {:halt, Phoenix.LiveView.redirect(socket, to: ~p"/admin")}
    else
      {:cont, assign(socket, :current_user, nil)}
    end
  end

  defp current_scope(nil), do: nil
  defp current_scope(user), do: %{user: user}

  defp ensure_active(_event, _params, socket) do
    case Administrators.fetch_active(socket.assigns.current_user) do
      {:ok, user} ->
        {:cont,
         socket
         |> assign(:current_user, user)
         |> assign(:current_scope, current_scope(user))}

      {:error, :inactive} ->
        {:halt,
         socket
         |> put_flash(:error, "This administrator account is disabled")
         |> redirect(to: ~p"/sign-in")}
    end
  end

  defp require_permissions(socket, permissions) do
    case socket.assigns[:current_user] do
      %{status: :active} = user ->
        if Authorization.any_allowed?(user, permissions) do
          socket =
            socket
            |> assign(:current_scope, current_scope(user))
            |> assign(:required_permissions, permissions)
            |> attach_hook(:authorized_administrator, :handle_event, &ensure_authorized/3)

          {:cont, socket}
        else
          forbidden(socket)
        end

      _ ->
        {:halt, redirect(socket, to: ~p"/sign-in")}
    end
  end

  defp ensure_authorized(_event, _params, socket) do
    with {:ok, user} <- Administrators.fetch_active(socket.assigns.current_user),
         true <- Authorization.any_allowed?(user, socket.assigns.required_permissions) do
      {:cont,
       socket
       |> assign(:current_user, user)
       |> assign(:current_scope, current_scope(user))}
    else
      {:error, :inactive} ->
        {:halt,
         socket
         |> put_flash(:error, "This administrator account is disabled")
         |> redirect(to: ~p"/sign-in")}

      false ->
        forbidden(socket)
    end
  end

  defp forbidden(socket) do
    {:halt,
     socket
     |> put_flash(:error, "You do not have permission to access this area")
     |> redirect(to: ~p"/admin")}
  end
end
