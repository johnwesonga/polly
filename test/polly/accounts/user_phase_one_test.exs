defmodule Polly.Accounts.UserPhaseOneTest do
  use Polly.DataCase, async: false

  alias Polly.Accounts.User

  describe "role and status defaults" do
    test "new accounts default to administrator and active" do
      user = create_user!("default-role@example.com")

      assert user.role == :administrator
      assert user.status == :active
      assert is_nil(user.disabled_at)
      assert is_nil(user.last_signed_in_at)
      assert %DateTime{} = user.inserted_at
      assert %DateTime{} = user.updated_at
    end

    test "a trusted registration may provide an explicit role" do
      user = create_user!("operator@example.com", :operator)

      assert user.role == :operator
      assert user.status == :active
    end
  end

  describe "owner recovery" do
    test "promotes a confirmed active account" do
      user = create_user!("recoverable@example.com") |> confirm!()

      owner = Ash.update!(user, %{}, action: :recover_owner, authorize?: false)

      assert owner.role == :owner
      assert owner.status == :active
    end

    test "refuses to promote an unconfirmed account" do
      user = create_user!("unconfirmed@example.com")

      assert {:error, error} =
               Ash.update(user, %{}, action: :recover_owner, authorize?: false)

      assert Exception.message(error) =~ "must be confirmed"
    end
  end

  defp create_user!(email, role \\ :administrator) do
    Ash.create!(
      User,
      %{
        email: email,
        password: "a secure password",
        password_confirmation: "a secure password",
        role: role
      },
      action: :register_with_password,
      authorize?: false
    )
  end

  defp confirm!(user) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    Polly.Repo.query!("UPDATE users SET confirmed_at = ? WHERE id = ?", [now, user.id])

    Ash.get!(User, user.id, authorize?: false)
  end
end
