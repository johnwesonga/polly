defmodule Polly.Accounts.AdministratorsTest do
  use Polly.DataCase, async: false

  alias Polly.Accounts.{Administrators, Token, User}
  alias Polly.Audit.Event

  require Ash.Query

  describe "disable/2 and enable/2" do
    test "an owner disables another account, revokes its sessions, and records an audit event" do
      owner = create_user!(:owner)
      target = create_user!(:administrator)
      subject = AshAuthentication.user_to_subject(target)

      assert token_count(subject) > 0
      assert {:ok, disabled} = Administrators.disable(target, owner)
      assert disabled.status == :disabled
      assert %DateTime{} = disabled.disabled_at
      assert token_count(subject) == 0

      event = event!("administrator.disabled", target.id)
      assert event.actor_id == owner.id
      assert event.target_label == to_string(target.email)

      assert {:ok, enabled} = Administrators.enable(disabled, owner)
      assert enabled.status == :active
      assert is_nil(enabled.disabled_at)
      assert event!("administrator.enabled", target.id)
    end

    test "rejects self-deactivation and non-owner actors" do
      owner = create_user!(:owner)
      administrator = create_user!(:administrator)

      assert {:error, :cannot_disable_self} = Administrators.disable(owner, owner)
      assert {:error, :unauthorized} = Administrators.disable(owner, administrator)
      assert Ash.get!(User, owner.id, authorize?: false).status == :active
    end
  end

  describe "change_role/3" do
    test "changes a role, revokes sessions, and records old and new roles" do
      owner = create_user!(:owner)
      target = create_user!(:administrator)
      subject = AshAuthentication.user_to_subject(target)

      assert {:ok, auditor} = Administrators.change_role(target, :auditor, owner)
      assert auditor.role == :auditor
      assert token_count(subject) == 0

      event = event!("administrator.role_changed", target.id)
      assert event.metadata == %{"old_role" => "administrator", "new_role" => "auditor"}
    end

    test "refuses to demote the final active owner" do
      owner = create_user!(:owner)

      assert {:error, :last_active_owner} =
               Administrators.change_role(owner, :administrator, owner)

      assert Ash.get!(User, owner.id, authorize?: false).role == :owner
    end

    test "allows one of multiple owners to be demoted" do
      first_owner = create_user!(:owner)
      second_owner = create_user!(:owner)

      assert {:ok, updated} =
               Administrators.change_role(first_owner, :administrator, second_owner)

      assert updated.role == :administrator
      assert Ash.get!(User, second_owner.id, authorize?: false).role == :owner
    end

    test "the database prevents a racing write from removing the final active owner" do
      owner = create_user!(:owner)

      assert {:error, error} =
               Polly.Repo.query("UPDATE users SET role = 'administrator' WHERE id = ?", [owner.id])

      assert Exception.message(error) =~ "last_active_owner"
      assert Ash.get!(User, owner.id, authorize?: false).role == :owner
    end
  end

  describe "authentication state" do
    test "disabled accounts are excluded from password and subject authentication" do
      owner = create_user!(:owner)
      target = create_user!(:administrator, password: "secure-password")
      assert {:ok, _disabled} = Administrators.disable(target, owner)

      assert {:error, _error} =
               User
               |> Ash.Query.for_read(:sign_in_with_password, %{
                 email: target.email,
                 password: "secure-password"
               })
               |> Ash.read_one(authorize?: false)

      assert {:error, _error} =
               User
               |> Ash.Query.for_read(:get_by_subject, %{
                 subject: AshAuthentication.user_to_subject(target)
               })
               |> Ash.read_one(authorize?: false, not_found_error?: true)
    end

    test "record_sign_in updates active users and refuses disabled users" do
      owner = create_user!(:owner)
      target = create_user!(:administrator)

      assert {:ok, signed_in} = Administrators.record_sign_in(target)
      assert %DateTime{} = signed_in.last_signed_in_at

      assert {:ok, disabled} = Administrators.disable(signed_in, owner)
      assert {:error, :account_disabled} = Administrators.record_sign_in(disabled)
    end
  end

  defp create_user!(role, options \\ []) do
    password = Keyword.get(options, :password, "secure-password")
    unique = System.unique_integer([:positive])

    Ash.create!(
      User,
      %{
        email: "phase-two-#{unique}@example.com",
        password: password,
        password_confirmation: password,
        role: role
      },
      action: :register_with_password,
      authorize?: false
    )
  end

  defp token_count(subject) do
    Token
    |> Ash.Query.filter(subject == ^subject and purpose == "user")
    |> Ash.count!(authorize?: false)
  end

  defp event!(action, target_id) do
    Event
    |> Ash.Query.filter(action == ^action and target_id == ^target_id)
    |> Ash.read_one!(authorize?: false)
  end
end
