defmodule PollyWeb.Plugs.RequireAdministrator do
  @moduledoc "Requires a session-authenticated Polly administrator for controller routes."

  import Phoenix.Controller, only: [put_flash: 3, redirect: 2]
  import Plug.Conn

  alias Polly.Accounts.User

  def init(opts), do: opts

  def call(%Plug.Conn{assigns: %{current_user: %User{}}} = conn, _opts), do: conn

  def call(conn, _opts) do
    conn
    |> put_session(:return_to, conn.request_path)
    |> put_flash(:error, "Sign in to continue")
    |> redirect(to: "/sign-in")
    |> halt()
  end
end
