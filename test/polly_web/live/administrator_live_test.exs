defmodule PollyWeb.AdministratorLiveTest do
  use PollyWeb.ConnCase, async: false

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

  defp confirm!(user) do
    confirmed_at = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    Polly.Repo.query!("UPDATE users SET confirmed_at = ? WHERE id = ?", [confirmed_at, user.id])
  end
end
