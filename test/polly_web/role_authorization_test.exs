defmodule PollyWeb.RoleAuthorizationTest do
  use PollyWeb.ConnCase, async: false

  alias Polly.Accounts.User

  test "auditors can view polls and audit history but not configuration", %{conn: conn} do
    auditor = create_user!(:auditor)

    {:ok, _view, _html} = conn |> sign_in(auditor) |> live(~p"/admin/polls")
    {:ok, _view, _html} = conn |> sign_in(auditor) |> live(~p"/admin/audit")

    assert {:error, {:redirect, %{to: "/admin"}}} =
             conn |> sign_in(auditor) |> live(~p"/admin/members")

    assert {:error, {:redirect, %{to: "/admin"}}} =
             conn |> sign_in(auditor) |> live(~p"/admin/polls/new")
  end

  test "operators only receive job-monitoring navigation", %{conn: conn} do
    operator = create_user!(:operator)
    {:ok, view, _html} = conn |> sign_in(operator) |> live(~p"/admin")

    assert has_element?(view, "#admin-nav-background-jobs")
    assert has_element?(view, "#job-monitoring-card")
    refute has_element?(view, "#admin-nav-members")
    refute has_element?(view, "#admin-nav-polls")
    refute has_element?(view, "#admin-nav-audit")

    assert {:error, {:redirect, %{to: "/admin"}}} =
             conn |> sign_in(operator) |> live(~p"/admin/audit")
  end

  test "result exports return 403 before resource lookup when permission is missing", %{
    conn: conn
  } do
    poll_id = Ecto.UUID.generate()

    operator_conn =
      conn
      |> sign_in(create_user!(:operator))
      |> get(~p"/admin/polls/#{poll_id}/results.csv")

    assert response(operator_conn, 403) == "You do not have permission to access this area"

    auditor_conn =
      build_conn()
      |> sign_in(create_user!(:auditor))
      |> get(~p"/admin/polls/#{poll_id}/results.csv")

    assert response(auditor_conn, 404) == "Not found"
  end

  test "Oban Web is read-only only for owners and operators" do
    assert PollyWeb.ObanWebResolver.resolve_access(create_user!(:owner)) == :read_only
    assert PollyWeb.ObanWebResolver.resolve_access(create_user!(:operator)) == :read_only

    assert PollyWeb.ObanWebResolver.resolve_access(create_user!(:administrator)) ==
             {:forbidden, "/admin"}

    assert PollyWeb.ObanWebResolver.resolve_access(create_user!(:auditor)) ==
             {:forbidden, "/admin"}

    assert PollyWeb.ObanWebResolver.resolve_access(nil) == {:forbidden, "/sign-in"}
  end

  defp sign_in(conn, user) do
    conn
    |> init_test_session(%{})
    |> AshAuthentication.Plug.Helpers.store_in_session(user)
  end

  defp create_user!(role) do
    Ash.create!(
      User,
      %{
        email: "web-role-#{role}-#{System.unique_integer([:positive])}@example.com",
        password: "secure-password",
        password_confirmation: "secure-password",
        role: role
      },
      action: :register_with_password,
      authorize?: false
    )
  end
end
