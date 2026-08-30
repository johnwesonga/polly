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

  test "shows database-backed poll summary counts to permitted users", %{conn: conn} do
    owner = create_user!(:owner, "summary-owner@example.com")

    draft = create_poll!(owner, "Dashboard draft")
    open = create_poll!(owner, "Dashboard open")
    unpublished = create_poll!(owner, "Dashboard unpublished")
    published = create_poll!(owner, "Dashboard published")

    set_poll_state!(open.id, "open", nil)
    set_poll_state!(unpublished.id, "closed", nil)
    set_poll_state!(published.id, "closed", DateTime.utc_now())

    view = conn |> sign_in(owner) |> mount()

    assert has_element?(view, "#dashboard-poll-summary")
    assert has_element?(view, "#dashboard-draft-polls[href='/admin/polls?status=draft']", "1")
    assert has_element?(view, "#dashboard-open-polls[href='/admin/polls?status=open']", "1")

    assert has_element?(
             view,
             "#dashboard-closed-polls[href='/admin/polls?status=all_closed']",
             "2"
           )

    assert has_element?(
             view,
             "#dashboard-unpublished-polls[href='/admin/polls?status=closed']",
             "1"
           )

    assert has_element?(view, "#dashboard-attention-missing_options", "1 draft needs options")
    assert has_element?(view, "#dashboard-attention-missing_electorate", "1 draft needs members")

    assert has_element?(
             view,
             "#dashboard-attention-unsent_invitations",
             "1 open poll has no accepted deliveries"
           )

    assert has_element?(
             view,
             "#dashboard-attention-unpublished_results",
             "1 result awaits publication"
           )

    assert has_element?(
             view,
             "#dashboard-active-poll-#{open.id}[href='/admin/polls/#{open.id}/access']",
             "0 of 0 votes"
           )

    assert has_element?(view, "#dashboard-active-poll-#{open.id}", "0.0% turnout")
    assert has_element?(view, "#dashboard-active-poll-#{open.id}", "No deliveries")

    assert draft.status == :draft
  end

  test "shows a positive attention empty state", %{conn: conn} do
    owner = create_user!(:owner, "clear-dashboard-owner@example.com")
    view = conn |> sign_in(owner) |> mount()

    assert has_element?(view, "#dashboard-attention")
    assert has_element?(view, "#dashboard-attention-empty", "Nothing needs attention")
    assert has_element?(view, "#dashboard-active-polls-empty", "No polls are currently open")
  end

  test "does not reveal poll counts to operators", %{conn: conn} do
    operator = create_user!(:operator, "summary-operator@example.com")
    view = conn |> sign_in(operator) |> mount()

    refute has_element?(view, "#dashboard-poll-summary")
  end

  test "shows recent activity and account security to owners", %{conn: conn} do
    owner = create_user!(:owner, "phase-four-owner@example.com")
    _poll = create_poll!(owner, "Dashboard activity")

    Ash.create!(
      Polly.Accounts.AdministratorInvitation,
      %{
        email: "dashboard-expiring@example.com",
        role: :administrator,
        invited_by_id: owner.id,
        expires_at: DateTime.add(DateTime.utc_now(), 24, :hour)
      },
      action: :invite,
      authorize?: false
    )

    view = conn |> sign_in(owner) |> mount()

    assert has_element?(view, "#dashboard-recent-activity")
    assert has_element?(view, "#dashboard-recent-events[phx-update='stream']")

    assert has_element?(view, "#dashboard-recent-activity a[href='/admin/audit']")
    assert has_element?(view, "#dashboard-recent-activity", "created poll “Dashboard activity”")
    assert has_element?(view, "#dashboard-account-health")

    assert has_element?(
             view,
             "#dashboard-account-health a[href='/admin/administrators']"
           )

    assert has_element?(view, "#dashboard-active-owner-count", "1")
    assert has_element?(view, "#dashboard-final-owner-warning", "Only one active owner remains")

    assert has_element?(
             view,
             "#dashboard-expiring-invitations-warning",
             "1 administrator invitation expires within 48 hours"
           )
  end

  test "shows authorized audit activity without leaking account health", %{conn: conn} do
    owner = create_user!(:owner, "activity-source-owner@example.com")
    _poll = create_poll!(owner, "Auditor-visible activity")

    auditor_view =
      conn
      |> sign_in(create_user!(:auditor, "phase-four-auditor@example.com"))
      |> mount()

    assert has_element?(auditor_view, "#dashboard-recent-activity")
    assert has_element?(auditor_view, "#dashboard-recent-activity", "Auditor-visible activity")
    refute has_element?(auditor_view, "#dashboard-account-health")

    administrator_view =
      conn
      |> sign_in(create_user!(:administrator, "phase-four-administrator@example.com"))
      |> mount()

    refute has_element?(administrator_view, "#dashboard-recent-activity")
    refute has_element?(administrator_view, "#dashboard-account-health")
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

  defp create_poll!(actor, title) do
    Ash.create!(
      Polly.Polls.Poll,
      %{title: title, description: "Dashboard summary"},
      action: :create_draft,
      actor: actor
    )
  end

  defp set_poll_state!(id, status, results_published_at) do
    Polly.Repo.query!(
      "UPDATE polls SET status = ?, results_published_at = ? WHERE id = ?",
      [status, results_published_at, id]
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
