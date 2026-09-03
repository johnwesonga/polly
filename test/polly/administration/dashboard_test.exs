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
              active_polls: [],
              recent_events: [],
              account_health: nil
            }} =
             Dashboard.load(actor)
  end

  test "reports overlapping attention conditions and limits auditors to result items" do
    owner = create_user!(:owner, "attention-owner@example.com")

    draft =
      Ash.create!(
        Polly.Polls.Poll,
        %{title: "Needs setup"},
        action: :create_draft,
        actor: owner
      )

    closed =
      Ash.create!(
        Polly.Polls.Poll,
        %{title: "Needs publication"},
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
    disabled = create_user!(:administrator, "dashboard-disabled@example.com")
    Polly.Repo.query!("UPDATE users SET status = 'disabled' WHERE id = ?", [disabled.id])

    assert {:error, :forbidden} = Dashboard.load(operator)
    assert {:error, :forbidden} = Dashboard.load(%{disabled | status: :disabled})
    assert {:error, :forbidden} = Dashboard.load(nil)
  end

  test "counts every poll lifecycle and publication combination" do
    owner = create_user!(:owner, "count-owner@example.com")
    draft = create_poll!(owner, "Count draft")
    open = create_poll!(owner, "Count open")
    unpublished = create_poll!(owner, "Count unpublished")
    published = create_poll!(owner, "Count published")

    set_poll_state!(open.id, "open", nil)
    set_poll_state!(unpublished.id, "closed", nil)
    set_poll_state!(published.id, "closed", DateTime.utc_now())

    assert {:ok, %{poll_counts: %{draft: 1, open: 1, closed: 2, unpublished: 1}}} =
             Dashboard.load(owner)

    assert draft.status == :draft
  end

  test "tracks unsent and failed invitation conditions from current delivery state" do
    owner = create_user!(:owner, "delivery-attention-owner@example.com")
    poll = create_ready_poll!(owner)

    assert {:ok, %{attention_items: items}} = Dashboard.load(owner)
    assert %{count: 1} = find_item(items, :unsent_invitations)
    refute find_item(items, :failed_deliveries)

    delivery =
      Ash.create!(
        Polly.Polls.InvitationDelivery,
        %{
          poll_id: poll.id,
          member_id: poll.member.id,
          access_grant_id: poll.grant.id,
          requested_by_id: owner.id,
          operation_id: Ash.UUID.generate(),
          kind: :initial,
          dedupe_key: "dashboard-delivery-attention",
          recipient_email: "dashboard-voter@example.com",
          credential_version: poll.grant.credential_version
        },
        action: :queue,
        actor: owner
      )

    failed =
      Ash.update!(
        delivery,
        %{attempt_count: 1, last_error_code: "provider_rejected"},
        action: :fail,
        authorize?: false
      )

    assert {:ok, %{attention_items: failed_items}} = Dashboard.load(owner)
    assert %{count: 1} = find_item(failed_items, :unsent_invitations)
    assert %{count: 1} = find_item(failed_items, :failed_deliveries)

    Ash.update!(
      failed,
      %{attempt_count: 2, provider_message_id: "provider-message"},
      action: :accept,
      authorize?: false
    )

    assert {:ok, %{attention_items: accepted_items}} = Dashboard.load(owner)
    refute find_item(accepted_items, :unsent_invitations)
    refute find_item(accepted_items, :failed_deliveries)
  end

  test "returns batched turnout and permission-aware destinations for open polls" do
    owner = create_user!(:owner, "active-owner@example.com")
    poll = create_ready_poll!(owner)

    assert {:ok, _ballot} =
             Polly.Polls.Ballots.submit(poll.id, voting_token(poll.grant), [poll.option.id])

    assert {:ok, %{active_polls: [active]}} = Dashboard.load(owner)
    assert active.id == poll.id
    assert active.opened_at == poll.opened_at
    assert active.participation_count == 1
    assert active.eligible_count == 1
    assert active.turnout_percentage == Polly.Polls.Results.for_poll(poll.id).turnout_percentage
    assert active.destination == "/admin/polls/#{poll.id}/access"

    auditor = create_user!(:auditor, "active-auditor@example.com")
    assert {:ok, %{active_polls: [read_only]}} = Dashboard.load(auditor)
    assert read_only.destination == "/admin/polls/#{poll.id}/results"
  end

  test "limits active polls to the five most recently updated" do
    owner = create_user!(:owner, "active-limit-owner@example.com")

    polls =
      for number <- 1..6 do
        poll =
          Ash.create!(
            Polly.Polls.Poll,
            %{title: "Open poll #{number}"},
            action: :create_draft,
            actor: owner
          )

        Polly.Repo.query!("UPDATE polls SET status = 'open' WHERE id = ?", [poll.id])
        poll
      end

    timestamp = DateTime.utc_now()

    Enum.each(polls, fn poll ->
      Polly.Repo.query!("UPDATE polls SET updated_at = ? WHERE id = ?", [timestamp, poll.id])
    end)

    assert {:ok, %{active_polls: active_polls}} = Dashboard.load(owner)
    assert length(active_polls) == 5
    assert Enum.map(active_polls, & &1.title) == Enum.map(1..5, &"Open poll #{&1}")
  end

  test "returns the five most recent audit events only to permitted actors" do
    owner = create_user!(:owner, "activity-owner@example.com")

    for number <- 1..6 do
      Ash.create!(
        Polly.Polls.Poll,
        %{title: "Recent activity #{number}"},
        action: :create_draft,
        actor: owner
      )
    end

    assert {:ok, %{recent_events: owner_events}} = Dashboard.load(owner)
    assert length(owner_events) == 5
    assert Enum.all?(owner_events, &(&1.action == "poll.created"))
    refute Enum.any?(owner_events, &(&1.target_label == "Recent activity 1"))

    auditor = create_user!(:auditor, "activity-auditor@example.com")
    assert {:ok, %{recent_events: auditor_events}} = Dashboard.load(auditor)
    assert Enum.map(auditor_events, & &1.id) == Enum.map(owner_events, & &1.id)

    administrator = create_user!(:administrator, "activity-administrator@example.com")
    assert {:ok, %{recent_events: nil}} = Dashboard.load(administrator)
  end

  test "returns account security counts only to owners" do
    owner = create_user!(:owner, "security-owner@example.com")
    administrator = create_user!(:administrator, "security-administrator@example.com")

    Polly.Repo.query!("UPDATE users SET status = 'disabled' WHERE id = ?", [administrator.id])

    Ash.create!(
      Polly.Accounts.AdministratorInvitation,
      %{
        email: "expiring-invitation@example.com",
        role: :auditor,
        invited_by_id: owner.id,
        expires_at: DateTime.add(DateTime.utc_now(), 24, :hour)
      },
      action: :invite,
      authorize?: false
    )

    assert {:ok, %{account_health: health}} = Dashboard.load(owner)
    assert health.active_owners == 1
    assert health.disabled_accounts == 1
    assert health.unconfirmed_accounts == 2
    assert health.pending_invitations == 1
    assert health.expiring_invitations == 1
    assert health.final_owner?

    auditor = create_user!(:auditor, "security-auditor@example.com")
    assert {:ok, %{account_health: nil}} = Dashboard.load(auditor)
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

  defp create_poll!(actor, title) do
    Ash.create!(
      Polly.Polls.Poll,
      %{title: title},
      action: :create_draft,
      actor: actor
    )
  end

  defp set_poll_state!(id, status, results_published_at) do
    Polly.Repo.query!(
      "UPDATE polls SET status = ?, results_published_at = ? WHERE id = ?",
      [status, results_published_at, id]
    )
  end

  defp create_ready_poll!(actor) do
    poll =
      Ash.create!(
        Polly.Polls.Poll,
        %{title: "Active dashboard poll"},
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
    %{id: poll.id, opened_at: poll.opened_at, option: option, grant: grant, member: member}
  end
end
