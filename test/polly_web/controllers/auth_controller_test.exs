defmodule PollyWeb.AuthControllerTest do
  use PollyWeb.ConnCase

  alias PollyWeb.AuthController

  test "successful sign-in redirects to the admin dashboard by default", %{conn: conn} do
    {conn, administrator} = register_and_log_in_administrator(conn)
    conn = Phoenix.Controller.fetch_flash(conn, [])

    conn = AuthController.success(conn, {:password, :sign_in}, administrator, "token")

    assert redirected_to(conn) == ~p"/admin"
  end

  test "successful sign-in preserves an explicit return destination", %{conn: conn} do
    {conn, administrator} = register_and_log_in_administrator(conn)

    conn =
      conn
      |> put_session(:return_to, ~p"/admin/polls")
      |> Phoenix.Controller.fetch_flash([])
      |> AuthController.success({:password, :sign_in}, administrator, "token")

    assert redirected_to(conn) == ~p"/admin/polls"
  end
end
