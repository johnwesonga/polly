defmodule PollyWeb.AdministratorLiveTest do
  use PollyWeb.ConnCase, async: false
  use Oban.Testing, repo: Polly.Repo

  alias Polly.Accounts.{Administrators, User}

  test "lists account role, status, confirmation, and sign-in information", %{conn: conn} do
    owner = create_user!(:owner, "owner-directory@example.com")
    administrator = create_user!(:administrator, "administrator-directory@example.com")
    auditor = create_user!(:auditor, "auditor-directory@example.com")

    {:ok, administrator} = Administrators.record_sign_in(administrator)
    confirm!(administrator)
    {:ok, auditor} = Administrators.disable(auditor, owner)

    conn =
      conn
      |> init_test_session(%{})
      |> AshAuthentication.Plug.Helpers.store_in_session(owner)

    {:ok, view, _html} = live(conn, ~p"/admin/administrators")

    assert has_element?(view, "#administrator-management-page")
    assert has_element?(view, "#administrator-account-#{owner.id}", "owner-directory@example.com")
    assert has_element?(view, "#administrator-account-you-#{owner.id}", "You")
    assert has_element?(view, "#administrator-account-role-#{owner.id}", "Owner")

    assert has_element?(
             view,
             "#administrator-account-role-#{administrator.id}",
             "Administrator"
           )

    assert has_element?(view, "#administrator-account-status-#{administrator.id}", "Active")

    assert has_element?(
             view,
             "#administrator-account-confirmation-#{administrator.id}",
             "Confirmed"
           )

    refute has_element?(
             view,
             "#administrator-account-last-sign-in-#{administrator.id}",
             "Never"
           )

    assert has_element?(view, "#administrator-account-role-#{auditor.id}", "Auditor")
    assert has_element?(view, "#administrator-account-status-#{auditor.id}", "Disabled")
    assert has_element?(view, "#administrator-account-confirmation-#{auditor.id}", "Unconfirmed")
    assert has_element?(view, "#administrator-account-last-sign-in-#{auditor.id}", "Never")
  end

  test "an owner disables, enables, and changes another account's role", %{conn: conn} do
    owner = create_user!(:owner, "owner-actions@example.com")
    target = create_user!(:administrator, "target-actions@example.com")
    view = mount_as(conn, owner)

    view
    |> element("#administrator-disable-#{target.id}")
    |> render_click()

    assert has_element?(view, "#administrator-action-confirmation-overlay")
    assert has_element?(view, "#confirm-administrator-action")

    assert has_element?(
             view,
             "#administrator-action-confirmation",
             "active sessions will be revoked"
           )

    view
    |> element("#confirm-administrator-action")
    |> render_click()

    assert Ash.get!(User, target.id, authorize?: false).status == :disabled
    assert has_element?(view, "#administrator-account-status-#{target.id}", "Disabled")
    assert has_element?(view, "#administrator-enable-#{target.id}")

    view
    |> element("#administrator-enable-#{target.id}")
    |> render_click()

    view
    |> element("#confirm-administrator-action")
    |> render_click()

    assert Ash.get!(User, target.id, authorize?: false).status == :active
    assert has_element?(view, "#administrator-account-status-#{target.id}", "Active")

    view
    |> form("#administrator-role-form-#{target.id}", account: %{role: "auditor"})
    |> render_submit()

    assert has_element?(
             view,
             "#administrator-action-confirmation",
             "active sessions will be revoked"
           )

    view
    |> element("#confirm-administrator-action")
    |> render_click()

    assert Ash.get!(User, target.id, authorize?: false).role == :auditor
    assert has_element?(view, "#administrator-account-role-#{target.id}", "Auditor")
  end

  test "requires confirmation before granting owner access", %{conn: conn} do
    owner = create_user!(:owner, "owner-elevation@example.com")
    target = create_user!(:auditor, "target-elevation@example.com")
    view = mount_as(conn, owner)

    view
    |> form("#administrator-role-form-#{target.id}", account: %{role: "owner"})
    |> render_submit()

    assert has_element?(view, "#administrator-action-confirmation-overlay", "Grant owner access?")
    assert Ash.get!(User, target.id, authorize?: false).role == :auditor

    view
    |> element("#cancel-administrator-action")
    |> render_click()

    refute has_element?(view, "#administrator-action-confirmation-overlay")
    assert Ash.get!(User, target.id, authorize?: false).role == :auditor
  end

  test "disables self-deactivation and final-owner role changes", %{conn: conn} do
    owner = create_user!(:owner, "protected-owner@example.com")
    view = mount_as(conn, owner)

    assert has_element?(view, "#administrator-disable-#{owner.id}[disabled]")
    assert has_element?(view, "#administrator-change-role-#{owner.id}[disabled]")

    assert has_element?(
             view,
             "#administrator-owner-protection-#{owner.id}",
             "Add another active owner"
           )
  end

  test "surfaces stale final-owner errors and refreshes the account list", %{conn: conn} do
    actor = create_user!(:owner, "stale-actor@example.com")
    other_owner = create_user!(:owner, "stale-other-owner@example.com")
    view = mount_as(conn, actor)

    view
    |> form("#administrator-role-form-#{actor.id}", account: %{role: "auditor"})
    |> render_submit()

    assert has_element?(view, "#administrator-action-confirmation-overlay")

    assert {:ok, _updated} =
             Administrators.change_role(other_owner, :administrator, actor)

    view
    |> element("#confirm-administrator-action")
    |> render_click()

    assert has_element?(view, "#flash-group", "Polly must retain at least one active owner")
    assert Ash.get!(User, actor.id, authorize?: false).role == :owner
    assert has_element?(view, "#administrator-account-role-#{actor.id}", "Owner")
    assert has_element?(view, "#administrator-change-role-#{actor.id}[disabled]")
    refute has_element?(view, "#administrator-action-confirmation-overlay")
  end

  test "an owner queues an administrator invitation without choosing a password", %{conn: conn} do
    owner = create_user!(:owner, "inviting-owner@example.com")
    view = mount_as(conn, owner)

    refute has_element?(view, "#administrator-invitation-form input[type=password]")

    view
    |> form("#administrator-invitation-form",
      invitation: %{email: "New.Admin@Example.com", role: "administrator"}
    )
    |> render_submit()

    assert has_element?(view, "#flash-group", "Administrator invitation queued")
    assert has_element?(view, "#administrator-invitations", "new.admin@example.com")

    assert [%Oban.Job{args: %{"invitation_id" => invitation_id}}] = all_enqueued()
    refute Map.has_key?(hd(all_enqueued()).args, "token")

    invitation =
      Ash.get!(Polly.Accounts.AdministratorInvitation, invitation_id, authorize?: false)

    assert invitation.role == :administrator
    assert invitation.status == :pending
  end

  test "owner invitations require an additional confirmation", %{conn: conn} do
    owner = create_user!(:owner, "inviting-an-owner@example.com")
    view = mount_as(conn, owner)

    view
    |> form("#administrator-invitation-form",
      invitation: %{email: "second-owner@example.com", role: "owner"}
    )
    |> render_submit()

    assert has_element?(view, "#owner-invitation-confirmation-overlay", "Grant owner access?")
    assert all_enqueued() == []

    view |> element("#confirm-owner-invitation") |> render_click()

    assert [_job] = all_enqueued()
    assert has_element?(view, "#administrator-invitations", "second-owner@example.com")
  end

  test "invitation form rejects existing accounts and duplicate pending invitations", %{
    conn: conn
  } do
    owner = create_user!(:owner, "guard-inviter@example.com")
    _existing = create_user!(:administrator, "existing-account@example.com")
    view = mount_as(conn, owner)

    view
    |> form("#administrator-invitation-form",
      invitation: %{email: "existing-account@example.com", role: "operator"}
    )
    |> render_submit()

    assert has_element?(view, "#flash-group", "An account already exists")
    assert all_enqueued() == []

    params = %{email: "pending-duplicate@example.com", role: "operator"}
    view |> form("#administrator-invitation-form", invitation: params) |> render_submit()
    assert [_job] = all_enqueued()

    view |> form("#administrator-invitation-form", invitation: params) |> render_submit()
    assert has_element?(view, "#flash-group", "A pending invitation already exists")
    assert length(all_enqueued()) == 1
  end

  defp create_user!(role, email) do
    Ash.create!(
      User,
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

  defp mount_as(conn, user) do
    conn =
      conn
      |> init_test_session(%{})
      |> AshAuthentication.Plug.Helpers.store_in_session(user)

    {:ok, view, _html} = live(conn, ~p"/admin/administrators")
    view
  end

  defp confirm!(user) do
    confirmed_at = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    Polly.Repo.query!("UPDATE users SET confirmed_at = ? WHERE id = ?", [confirmed_at, user.id])
  end
end
