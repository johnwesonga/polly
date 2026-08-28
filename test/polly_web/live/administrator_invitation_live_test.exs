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
