defmodule Polly.Polls.ReadinessTest do
  use Polly.DataCase

  alias Polly.Accounts.User
  alias Polly.Polls.{Poll, Readiness}

  test "returns manager readiness counts without exposing them to auditors" do
    owner = create_user!(:owner, "readiness-owner@example.com")

    Ash.create!(
      Poll,
      %{title: "Readiness draft"},
      action: :create_draft,
      actor: owner
    )

    assert {:ok, manager_counts} = Readiness.attention_counts(owner)
    assert manager_counts.missing_options == 1
    assert manager_counts.missing_electorate == 1

    auditor = create_user!(:auditor, "readiness-auditor@example.com")
    assert {:ok, auditor_counts} = Readiness.attention_counts(auditor)
    assert auditor_counts.missing_options == nil
    assert auditor_counts.missing_electorate == nil
    assert auditor_counts.unsent_invitations == nil
    assert auditor_counts.failed_deliveries == nil

    operator = create_user!(:operator, "readiness-operator@example.com")
    assert {:error, :forbidden} = Readiness.attention_counts(operator)
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
