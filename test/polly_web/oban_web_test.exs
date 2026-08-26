defmodule PollyWeb.ObanWebTest do
  use PollyWeb.ConnCase

  test "redirects unauthenticated visitors to sign in", %{conn: conn} do
    conn = get(conn, ~p"/admin/oban")

    assert redirected_to(conn) == ~p"/sign-in"
  end

  test "mounts the dashboard and grants administrators read-only access", %{conn: conn} do
    {_conn, administrator} = register_and_log_in_administrator(conn)

    assert :read_only == PollyWeb.ObanWebResolver.resolve_access(administrator)

    assert %{plug: Phoenix.LiveView.Plug} =
             Phoenix.Router.route_info(
               PollyWeb.Router,
               "GET",
               "/admin/oban",
               "localhost"
             )
  end

  test "resolver forbids anonymous access and never grants write access" do
    assert {:forbidden, "/sign-in"} == PollyWeb.ObanWebResolver.resolve_access(nil)
    assert :read_only == PollyWeb.ObanWebResolver.resolve_access(%{id: "administrator"})
  end
end
