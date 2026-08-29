defmodule Polly.Administration.DashboardTest do
  use Polly.DataCase, async: false

  alias Polly.Accounts.User
  alias Polly.Administration.Dashboard

  test "returns zero counts when no polls exist" do
    actor = create_user!(:auditor, "empty-dashboard@example.com")

    assert {:ok,
            %{
              poll_counts: %{draft: 0, open: 0, closed: 0, unpublished: 0},
              attention_items: [],
              active_polls: []
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

  test "returns batched turnout and permission-aware destinations for open polls" do
    owner = create_user!(:owner, "active-owner@example.com")
    poll = create_ready_poll!(owner)

    assert {:ok, _ballot} =
             Polly.Polls.Ballots.submit(poll.id, poll.grant.token, poll.option.id)

    assert {:ok, %{active_polls: [active]}} = Dashboard.load(owner)
    assert active.id == poll.id
    assert active.ballot_count == 1
    assert active.eligible_count == 1
    assert active.turnout_percentage == 100.0
    assert active.destination == "/admin/polls/#{poll.id}/access"

    auditor = create_user!(:auditor, "active-auditor@example.com")
    assert {:ok, %{active_polls: [read_only]}} = Dashboard.load(auditor)
    assert read_only.destination == "/admin/polls/#{poll.id}/results"
  end

  test "limits active polls to the five most recently updated" do
    owner = create_user!(:owner, "active-limit-owner@example.com")

    for number <- 1..6 do
      poll =
        Ash.create!(
          Polly.Polls.Poll,
          %{title: "Open poll #{number}", slug: "open-poll-#{number}"},
          action: :create_draft,
          actor: owner
        )

      Polly.Repo.query!("UPDATE polls SET status = 'open' WHERE id = ?", [poll.id])
    end

    assert {:ok, %{active_polls: active_polls}} = Dashboard.load(owner)
    assert length(active_polls) == 5
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

  defp create_ready_poll!(actor) do
    poll =
      Ash.create!(
        Polly.Polls.Poll,
        %{title: "Active dashboard poll", slug: "active-dashboard-poll"},
        action: :create_draft,
        actor: actor
      )

    option =
      Ash.create!(
        Polly.Polls.Option,
        %{poll_id: poll.id, label: "First", position: 1},
        actor: actor
      )

    Ash.create!(
      Polly.Polls.Option,
      %{poll_id: poll.id, label: "Second", position: 2},
      actor: actor
    )

    member =
      Ash.create!(
        Polly.Members.Member,
        %{name: "Dashboard voter", email: "dashboard-voter@example.com"},
        actor: actor
      )

    {_eligibility, grant} = Polly.Polls.Electorate.include_member(poll, member, actor)
    poll = Ash.update!(poll, %{}, action: :open, actor: actor)
    %{id: poll.id, option: option, grant: grant}
  end
end
