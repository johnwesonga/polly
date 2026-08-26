defmodule PollyWeb.AdminLiveTest do
  use PollyWeb.ConnCase

  import AshAuthentication.Plug.Helpers, only: [store_in_session: 2]

  test "redirects signed-out visitors to sign in", %{conn: conn} do
    assert {:error, {:redirect, %{to: "/sign-in"}}} = live(conn, ~p"/admin")
  end

  test "renders the admin overview for an authenticated administrator", %{conn: conn} do
    administrator =
      Ash.create!(
        Polly.Accounts.User,
        %{
          email: "admin@example.com",
          password: "secure-password",
          password_confirmation: "secure-password"
        },
        action: :register_with_password,
        authorize?: false
      )

    conn =
      conn
      |> init_test_session(%{})
      |> store_in_session(administrator)

    {:ok, view, _html} = live(conn, ~p"/admin")

    assert has_element?(view, "#admin-overview")
    assert has_element?(view, "#poll-management-card")
    assert has_element?(view, "#manage-polls-link")
    assert has_element?(view, "#admin-nav-background-jobs[href='/admin/oban']")
  end

  test "does not expose public administrator registration", %{conn: conn} do
    assert conn |> get("/register") |> response(404)
  end
end
