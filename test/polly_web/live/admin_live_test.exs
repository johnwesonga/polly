defmodule PollyWeb.AdminLiveTest do
  use PollyWeb.ConnCase

  import AshAuthentication.Plug.Helpers, only: [store_in_session: 2]

  test "redirects signed-out visitors to sign in", %{conn: conn} do
    assert {:error, {:redirect, %{to: "/sign-in"}}} = live(conn, ~p"/admin")
  end

  test "renders the page heading and poll-management quick actions", %{conn: conn} do
    administrator = create_user!(:administrator, "admin@example.com")
    conn = sign_in(conn, administrator)

    {:ok, view, _html} = live(conn, ~p"/admin")

    assert has_element?(view, "#admin-overview")
    assert has_element?(view, "#admin-overview", "Here’s what needs your attention today.")
    assert has_element?(view, "#dashboard-quick-actions[aria-label='Quick actions']")
    assert has_element?(view, "#create-poll-action[href='/admin/polls/new']")
    assert has_element?(view, "#import-members-action[href='/admin/members/import']")
    refute has_element?(view, "#view-results-action")
    refute has_element?(view, "#view-audit-action")
    refute has_element?(view, "#view-jobs-action")
  end

  test "quick actions are composed from permissions", %{conn: conn} do
    auditor_view = conn |> sign_in(create_user!(:auditor, "auditor@example.com")) |> mount()

    assert has_element?(auditor_view, "#view-results-action[href='/admin/polls']")
    assert has_element?(auditor_view, "#view-audit-action[href='/admin/audit']")
    refute has_element?(auditor_view, "#create-poll-action")
    refute has_element?(auditor_view, "#import-members-action")
    refute has_element?(auditor_view, "#view-jobs-action")

    operator_view = conn |> sign_in(create_user!(:operator, "operator@example.com")) |> mount()

    assert has_element?(operator_view, "#view-jobs-action[href='/admin/oban']")
    refute has_element?(operator_view, "#create-poll-action")
    refute has_element?(operator_view, "#view-results-action")
  end

  test "owners see focused quick actions while full navigation remains in the sidebar", %{
    conn: conn
  } do
    owner_view = conn |> sign_in(create_user!(:owner, "owner@example.com")) |> mount()

    assert has_element?(owner_view, "#create-poll-action")
    assert has_element?(owner_view, "#import-members-action")
    refute has_element?(owner_view, "#view-results-action")
    refute has_element?(owner_view, "#view-audit-action")
    refute has_element?(owner_view, "#view-jobs-action")

    assert has_element?(owner_view, "#admin-nav-audit")
    assert has_element?(owner_view, "#admin-nav-background-jobs")
  end

  test "does not expose public administrator registration", %{conn: conn} do
    assert conn |> get("/register") |> response(404)
  end

  defp create_user!(role, email) do
    Ash.create!(
      Polly.Accounts.User,
      %{
        email: email,
        password: "secure-password",
        password_confirmation: "secure-password",
        role: role
      },
      action: :register_with_password,
      authorize?: false
    )
  end

  defp sign_in(conn, user) do
    conn
    |> recycle()
    |> init_test_session(%{})
    |> store_in_session(user)
  end

  defp mount(conn) do
    {:ok, view, _html} = live(conn, ~p"/admin")
    view
  end
end
