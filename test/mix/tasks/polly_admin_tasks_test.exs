defmodule Mix.Tasks.PollyAdminTasksTest do
  use Polly.DataCase, async: false

  import ExUnit.CaptureIO

  alias Polly.Accounts.User

  require Ash.Query

  setup do
    previous_password = System.get_env("POLLY_ADMIN_PASSWORD")
    System.put_env("POLLY_ADMIN_PASSWORD", "task password")

    on_exit(fn ->
      if previous_password do
        System.put_env("POLLY_ADMIN_PASSWORD", previous_password)
      else
        System.delete_env("POLLY_ADMIN_PASSWORD")
      end
    end)
  end

  test "create defaults to owner without exposing the password" do
    output = capture_io(fn -> Mix.Tasks.Polly.Admin.Create.run(["owner@example.com"]) end)
    user = get_user!("owner@example.com")

    assert user.role == :owner
    assert user.status == :active
    assert output =~ "Created owner administrator owner@example.com"
    refute output =~ "task password"
  end

  test "create accepts each explicit role" do
    for role <- [:owner, :administrator, :auditor, :operator] do
      email = "#{role}@example.com"

      capture_io(fn ->
        Mix.Tasks.Polly.Admin.Create.run([email, "--role", Atom.to_string(role)])
      end)

      assert get_user!(email).role == role
    end
  end

  test "create rejects invalid roles and duplicate emails" do
    assert_raise Mix.Error, ~r/invalid role/, fn ->
      Mix.Tasks.Polly.Admin.Create.run(["invalid@example.com", "--role", "superuser"])
    end

    capture_io(fn -> Mix.Tasks.Polly.Admin.Create.run(["duplicate@example.com"]) end)

    assert_raise Mix.Error, ~r/Could not create administrator/, fn ->
      capture_io(fn -> Mix.Tasks.Polly.Admin.Create.run(["duplicate@example.com"]) end)
    end
  end

  test "promote owner requires an existing confirmed account" do
    user = create_user!("promote@example.com") |> confirm!()

    output =
      capture_io(fn ->
        Mix.Tasks.Polly.Admin.PromoteOwner.run(["promote@example.com"])
      end)

    assert Ash.get!(User, user.id, authorize?: false).role == :owner
    assert output =~ "Promoted administrator promote@example.com"
    refute output =~ "task password"

    assert_raise Mix.Error, ~r/No administrator exists/, fn ->
      Mix.Tasks.Polly.Admin.PromoteOwner.run(["missing@example.com"])
    end
  end

  defp get_user!(email) do
    User
    |> Ash.Query.filter(email == ^email)
    |> Ash.read_one!(authorize?: false)
  end

  defp create_user!(email) do
    Ash.create!(
      User,
      %{
        email: email,
        password: "a secure password",
        password_confirmation: "a secure password"
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
