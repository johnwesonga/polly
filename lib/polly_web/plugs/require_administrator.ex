defmodule PollyWeb.Plugs.RequireAdministrator do
  @moduledoc "Requires a session-authenticated Polly administrator for controller routes."

  import Phoenix.Controller, only: [put_flash: 3, redirect: 2]
  import Plug.Conn

  alias Polly.Accounts.User
  alias Polly.Accounts.Authorization

  def init(opts), do: Keyword.fetch!(opts, :permission)

  def call(%Plug.Conn{assigns: %{current_user: %User{status: :active} = user}} = conn, permission) do
    if Authorization.allowed?(user, permission) do
      conn
    else
      conn
      |> put_resp_content_type("text/plain")
      |> send_resp(403, "You do not have permission to access this area")
      |> halt()
    end
  end

  def call(%Plug.Conn{assigns: %{current_user: %User{status: :disabled}}} = conn, _permission) do
    conn
    |> clear_session()
    |> put_flash(:error, "This administrator account is disabled")
    |> redirect(to: "/sign-in")
    |> halt()
  end

  def call(conn, _permission) do
    conn
    |> put_session(:return_to, conn.request_path)
    |> put_flash(:error, "Sign in to continue")
    |> redirect(to: "/sign-in")
    |> halt()
  end
end
