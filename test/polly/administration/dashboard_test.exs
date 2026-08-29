defmodule Polly.Administration.DashboardTest do
  use Polly.DataCase, async: false

  alias Polly.Accounts.User
  alias Polly.Administration.Dashboard

  test "returns zero counts when no polls exist" do
    actor = create_user!(:auditor, "empty-dashboard@example.com")

    assert {:ok,
            %{
              poll_counts: %{draft: 0, open: 0, closed: 0, unpublished: 0},
              attention_items: []
            }} =
             Dashboard.load(actor)
  end

  test "reports overlapping attention conditions and limits auditors to result items" do
    owner = create_user!(:owner, "attention-owner@example.com")

    draft =
      Ash.create!(
        Polly.Polls.Poll,
        %{title: "Needs setup", slug: "needs-setup"},
        action: :create_draft,
        actor: owner
      )

    closed =
      Ash.create!(
        Polly.Polls.Poll,
        %{title: "Needs publication", slug: "needs-publication"},
        action: :create_draft,
        actor: owner
      )

    Polly.Repo.query!("UPDATE polls SET status = 'closed' WHERE id = ?", [closed.id])

    assert {:ok, %{attention_items: items}} = Dashboard.load(owner)
    assert %{kind: :missing_options, count: 1} = find_item(items, :missing_options)
    assert %{kind: :missing_electorate, count: 1} = find_item(items, :missing_electorate)
    assert %{kind: :unpublished_results, count: 1} = find_item(items, :unpublished_results)
    assert draft.status == :draft

    auditor = create_user!(:auditor, "attention-auditor@example.com")
    assert {:ok, %{attention_items: [item]}} = Dashboard.load(auditor)
    assert item.kind == :unpublished_results
  end

  test "rejects actors without poll visibility" do
    operator = create_user!(:operator, "dashboard-operator@example.com")

    assert {:error, :forbidden} = Dashboard.load(operator)
    assert {:error, :forbidden} = Dashboard.load(nil)
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

  defp find_item(items, kind), do: Enum.find(items, &(&1.kind == kind))
end
