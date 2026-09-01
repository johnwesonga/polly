defmodule PollyWeb.RoleAuthorizationTest do
  use PollyWeb.ConnCase, async: false

  alias Polly.Accounts.User
  alias Polly.Members.Member
  alias Polly.Polls.Poll

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
    assert has_element?(view, "#admin-nav-background-jobs .hero-circle-stack")
    assert has_element?(view, "#view-jobs-action[href='/admin/oban']")
    refute has_element?(view, "#admin-nav-members")
    refute has_element?(view, "#admin-nav-polls")
    refute has_element?(view, "#admin-nav-administrators")
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

  test "access-managing roles cannot retrieve voting credentials from the UI", %{conn: conn} do
    owner = create_user!(:owner)
    poll = Ash.create!(Poll, %{title: "Protected credentials"}, actor: owner)

    member =
      Ash.create!(Member, %{name: "Protected voter", email: "voter@example.com"}, actor: owner)

    {_eligibility, grant} = Polly.Polls.Electorate.include_member(poll, member, owner)

    for role <- [:owner, :administrator] do
      user = if role == :owner, do: owner, else: create_user!(role)
      {:ok, view, _html} = conn |> sign_in(user) |> live(~p"/admin/polls/#{poll.id}/access")

      assert has_element?(view, "#protected-access-#{member.id}")
      refute has_element?(view, "#copy-access-link-#{member.id}")
      refute render(view) =~ voting_token(grant)
    end

    assert {:error, {:redirect, %{to: "/admin"}}} =
             conn
             |> sign_in(create_user!(:auditor))
             |> live(~p"/admin/polls/#{poll.id}/access")
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

  test "registers an owner-only administrator-management route", %{conn: conn} do
    assert %{plug: Phoenix.LiveView.Plug, plug_opts: plug_opts} =
             Phoenix.Router.route_info(
               PollyWeb.Router,
               "GET",
               "/admin/administrators",
               "localhost"
             )

    assert plug_opts == :index

    {:ok, owner_view, _html} =
      conn |> sign_in(create_user!(:owner)) |> live(~p"/admin/administrators")

    assert has_element?(owner_view, "#administrator-management-page")
    assert has_element?(owner_view, "#admin-nav-administrators.current", "Administrators")
    assert has_element?(owner_view, "#admin-nav-overview .hero-chart-bar")
    assert has_element?(owner_view, "#admin-nav-members .hero-user-group")
    assert has_element?(owner_view, "#admin-nav-polls .hero-list-bullet")
    assert has_element?(owner_view, "#admin-nav-administrators .hero-shield-check")
    assert has_element?(owner_view, "#admin-nav-audit .hero-document-text")
    assert has_element?(owner_view, ".navfoot", "Owner")

    {:ok, administrator_view, _html} =
      build_conn() |> sign_in(create_user!(:administrator)) |> live(~p"/admin")

    refute has_element?(administrator_view, "#admin-nav-administrators")

    assert {:error, {:redirect, %{to: "/admin"}}} =
             build_conn()
             |> sign_in(create_user!(:administrator))
             |> live(~p"/admin/administrators")
  end

  test "administrator management rejects every non-owner role", %{conn: conn} do
    for role <- [:administrator, :auditor, :operator] do
      assert {:error, {:redirect, %{to: "/admin"}}} =
               conn
               |> sign_in(create_user!(role))
               |> live(~p"/admin/administrators")
    end
  end

  test "administrator management rejects disabled and anonymous users", %{conn: conn} do
    owner = create_user!(:owner)
    disabled = create_user!(:administrator)
    assert {:ok, _disabled} = Polly.Accounts.Administrators.disable(disabled, owner)

    assert {:error, {:redirect, %{to: "/sign-in"}}} =
             conn
             |> sign_in(disabled)
             |> live(~p"/admin/administrators")

    assert {:error, {:redirect, %{to: "/sign-in"}}} =
             build_conn()
             |> init_test_session(%{})
             |> live(~p"/admin/administrators")
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
