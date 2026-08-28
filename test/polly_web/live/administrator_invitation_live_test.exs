defmodule PollyWeb.AdministratorInvitationLiveTest do
  use PollyWeb.ConnCase, async: false
  use Oban.Testing, repo: Polly.Repo

  import Swoosh.TestAssertions

  require Ash.Query

  alias Polly.Accounts.{
    AdministratorInvitation,
    AdministratorInvitationToken,
    AdministratorInvitationWorker,
    AdministratorInvitations,
    User
  }

  test "the recipient receives a private setup link and creates a confirmed account", %{
    conn: conn
  } do
    owner = create_user!(:owner, "setup-inviter@example.com")
    assert_email_sent()

    assert {:ok, invitation} =
             AdministratorInvitations.invite("recipient@example.com", :auditor, owner)

    assert [%Oban.Job{} = job] = all_enqueued(worker: AdministratorInvitationWorker)
    assert :ok = perform_job(AdministratorInvitationWorker, job.args)

    delivered = Ash.get!(AdministratorInvitation, invitation.id, authorize?: false)
    assert delivered.delivery_status == :sent
    assert delivered.send_count == 1
    assert delivered.sent_at

    assert_email_sent(fn email ->
      assert email.to == [{"", "recipient@example.com"}]
      assert email.text_body =~ "Do not forward or share it"
      assert email.html_body =~ "Set up your account"
    end)

    token = AdministratorInvitationToken.sign(invitation)

    {:ok, view, _html} =
      live(conn, ~p"/administrator-invitations/#{invitation.id}/setup?token=#{token}")

    assert has_element?(view, "#administrator-invitation-setup-form")

    view
    |> form("#administrator-invitation-setup-form",
      setup: %{password: "recipient-password", password_confirmation: "recipient-password"}
    )
    |> render_submit()

    assert_redirect(view, ~p"/sign-in")

    user =
      Ash.read_one!(Ash.Query.filter(User, email == "recipient@example.com"), authorize?: false)

    assert user.role == :auditor
    assert user.confirmed_at

    accepted = Ash.get!(AdministratorInvitation, invitation.id, authorize?: false)
    assert accepted.status == :accepted
    assert accepted.accepted_user_id == user.id
  end

  test "an invalid credential does not render the password form", %{conn: conn} do
    owner = create_user!(:owner, "invalid-inviter@example.com")
    assert_email_sent()

    assert {:ok, invitation} =
             AdministratorInvitations.invite("invalid@example.com", :operator, owner)

    {:ok, view, _html} =
      live(conn, ~p"/administrator-invitations/#{invitation.id}/setup?token=invalid")

    assert has_element?(view, "#administrator-invitation-setup", "Invitation unavailable")
    refute has_element?(view, "#administrator-invitation-setup-form")
  end

  test "revoked, expired, accepted, and invitation-bound credentials fail safely", %{conn: conn} do
    owner = create_user!(:owner, "credential-states-inviter@example.com")
    assert_email_sent()

    {:ok, revoked} = AdministratorInvitations.invite("revoked@example.com", :operator, owner)
    revoked_token = AdministratorInvitationToken.sign(revoked)
    assert {:ok, _} = AdministratorInvitations.revoke(revoked, owner)

    assert {:error, :invalid_invitation} =
             AdministratorInvitations.verify(revoked.id, revoked_token)

    {:ok, expired} = AdministratorInvitations.invite("expired@example.com", :operator, owner)
    expired_token = AdministratorInvitationToken.sign(expired)
    past = DateTime.add(DateTime.utc_now(), -1, :second) |> DateTime.truncate(:microsecond)

    Polly.Repo.query!(
      "UPDATE administrator_invitations SET expires_at = ? WHERE id = ?",
      [past, expired.id]
    )

    assert {:error, :invalid_invitation} =
             AdministratorInvitations.verify(expired.id, expired_token)

    {:ok, accepted} = AdministratorInvitations.invite("accepted@example.com", :auditor, owner)
    accepted_token = AdministratorInvitationToken.sign(accepted)

    assert {:ok, _user} =
             AdministratorInvitations.accept(
               accepted.id,
               accepted_token,
               "accepted-password",
               "accepted-password"
             )

    assert {:error, :invalid_invitation} =
             AdministratorInvitations.accept(
               accepted.id,
               accepted_token,
               "accepted-password",
               "accepted-password"
             )

    {:ok, other} = AdministratorInvitations.invite("other@example.com", :auditor, owner)
    refute AdministratorInvitationToken.valid?(other, accepted_token)

    {:ok, view, _html} =
      live(conn, ~p"/administrator-invitations/#{other.id}/setup?token=#{accepted_token}")

    assert has_element?(view, "#administrator-invitation-setup", "Invitation unavailable")
    refute has_element?(view, "#administrator-invitation-setup-form")
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
end
