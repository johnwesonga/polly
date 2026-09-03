defmodule Polly.Polls.InvitationsTest do
  use Polly.DataCase
  use Oban.Testing, repo: Polly.Repo

  import Swoosh.TestAssertions
  require Ash.Query

  alias Polly.Accounts.User
  alias Polly.Members.Member

  alias Polly.Polls.{
    InvitationDelivery,
    InvitationWorker,
    Invitations,
    Option,
    Participation,
    Poll
  }

  setup do
    actor =
      Ash.create!(
        User,
        %{
          email: "invitation-admin-#{System.unique_integer([:positive])}@example.com",
          password: "secure-password",
          password_confirmation: "secure-password"
        },
        action: :register_with_password,
        authorize?: false
      )

    assert_email_sent()
    %{actor: actor}
  end

  test "queues one initial invitation per ready grant and records an aggregate audit event", %{
    actor: actor
  } do
    {poll, _member, _grant} = open_poll_with_member!(actor)

    assert %{ready_count: 1, skipped_count: 0} = Invitations.preview(poll, actor)
    assert {:ok, [delivery]} = Invitations.enqueue_bulk(poll, actor)
    assert delivery.status == :queued
    assert delivery.kind == :initial
    assert delivery.credential_version == 1

    assert [%Oban.Job{args: %{"delivery_id" => delivery_id}}] = all_enqueued()
    assert delivery_id == delivery.id

    assert {:ok, []} = Invitations.enqueue_bulk(poll, actor)
    assert length(Ash.read!(InvitationDelivery, actor: actor)) == 1

    events =
      Polly.Audit.Event
      |> Ash.Query.filter(action == "poll.invitations_enqueued")
      |> Ash.read!(authorize?: false)

    assert length(events) == 2
    assert Enum.all?(events, &(not Map.has_key?(&1.metadata, "email")))
  end

  test "skips members without an email address", %{actor: actor} do
    poll = draft_poll!(actor)
    member = Ash.create!(Member, %{name: "No Email"}, actor: actor)
    Polly.Polls.Electorate.include_member(poll, member, actor)
    poll = open!(poll, actor)

    assert %{ready_count: 0, counts: %{missing_email: 1}} = Invitations.preview(poll, actor)
    assert {:ok, []} = Invitations.enqueue_bulk(poll, actor)
    assert all_enqueued() == []
  end

  test "readiness previews do not load voting credentials", %{actor: actor} do
    {poll, _member, _grant} = open_poll_with_member!(actor)

    assert %{recipients: [%{grant: grant}]} = Invitations.preview(poll, actor)
    assert %Ash.NotLoaded{} = grant.token
  end

  test "readiness skips members who have already submitted", %{actor: actor} do
    {poll, member, _grant} = open_poll_with_member!(actor)

    Ash.create!(
      Participation,
      %{poll_id: poll.id, member_id: member.id},
      action: :record,
      authorize?: false
    )

    assert %{ready_count: 0, counts: %{already_voted: 1}} = Invitations.preview(poll, actor)
  end

  test "worker sends the individualized private link and marks the delivery accepted", %{
    actor: actor
  } do
    {poll, member, grant} = open_poll_with_member!(actor)
    assert {:ok, [delivery]} = Invitations.enqueue_bulk(poll, actor)

    assert :ok =
             InvitationWorker.perform(%Oban.Job{
               args: %{"delivery_id" => delivery.id},
               attempt: 1,
               max_attempts: 5
             })

    delivery = Ash.get!(InvitationDelivery, delivery.id, actor: actor)
    assert delivery.status == :accepted
    assert delivery.attempt_count == 1

    assert_email_sent(fn email ->
      assert email.to == [{member.name, member.email}]
      assert email.subject == "Voting is open: #{poll.title}"
      assert email.text_body =~ "Selection rule: Choose one."
      assert email.text_body =~ voting_token(grant)
      assert email.html_body =~ "Touchpad"
      assert email.html_body =~ "Private poll invitation"
      assert email.html_body =~ "Selection rule:"
      assert email.html_body =~ "Choose one."
      assert email.html_body =~ "Cast your vote"
      assert email.html_body =~ "Keep this link private."
      assert email.html_body =~ voting_token(grant)
    end)
  end

  test "worker cancels when the grant is revoked before delivery", %{actor: actor} do
    {poll, _member, grant} = open_poll_with_member!(actor)
    assert {:ok, [delivery]} = Invitations.enqueue_bulk(poll, actor)
    Polly.Polls.Electorate.revoke(grant, actor)

    assert :ok =
             InvitationWorker.perform(%Oban.Job{
               args: %{"delivery_id" => delivery.id},
               attempt: 1,
               max_attempts: 5
             })

    assert Ash.get!(InvitationDelivery, delivery.id, actor: actor).status == :cancelled
    refute_email_sent()
  end

  test "worker cancels when the member submits after the invitation is queued", %{actor: actor} do
    {poll, member, _grant} = open_poll_with_member!(actor)
    assert {:ok, [delivery]} = Invitations.enqueue_bulk(poll, actor)

    Ash.create!(
      Participation,
      %{poll_id: poll.id, member_id: member.id},
      action: :record,
      authorize?: false
    )

    assert :ok =
             InvitationWorker.perform(%Oban.Job{
               args: %{"delivery_id" => delivery.id},
               attempt: 1,
               max_attempts: 5
             })

    delivery = Ash.get!(InvitationDelivery, delivery.id, actor: actor)
    assert delivery.status == :cancelled
    assert delivery.last_error_code == "already_voted"
    refute_email_sent()
  end

  test "worker cancels a delivery pinned to an older credential version", %{actor: actor} do
    {poll, _member, grant} = open_poll_with_member!(actor)
    assert {:ok, [delivery]} = Invitations.enqueue_bulk(poll, actor)

    Polly.Repo.query!(
      "UPDATE poll_access_grants SET credential_version = ? WHERE id = ?",
      [grant.credential_version + 1, grant.id]
    )

    assert :ok =
             InvitationWorker.perform(%Oban.Job{
               args: %{"delivery_id" => delivery.id},
               attempt: 1,
               max_attempts: 5
             })

    delivery = Ash.get!(InvitationDelivery, delivery.id, actor: actor)
    assert delivery.status == :cancelled
    assert delivery.last_error_code == "stale_credential"
    refute_email_sent()
  end

  test "legacy deliveries pin version zero and continue using their plaintext credential", %{
    actor: actor
  } do
    {poll, _member, grant} = open_poll_with_member!(actor)
    legacy_token = "legacy-" <> Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)

    Polly.Repo.query!(
      "UPDATE poll_access_grants SET token = ?, token_digest = NULL, credential_nonce = NULL, credential_version = 0, credential_issued_at = NULL WHERE id = ?",
      [legacy_token, grant.id]
    )

    assert {:ok, [delivery]} = Invitations.enqueue_bulk(poll, actor)
    assert delivery.credential_version == 0

    assert :ok =
             InvitationWorker.perform(%Oban.Job{
               args: %{"delivery_id" => delivery.id},
               attempt: 1,
               max_attempts: 5
             })

    assert_email_sent(fn email -> assert email.text_body =~ legacy_token end)
  end

  test "reminder preview requires an accepted invitation and excludes voters", %{actor: actor} do
    {poll, member, _grant} = open_poll_with_member!(actor)

    assert {:ok, %{ready_count: 0, counts: %{initial_invitation_required: 1}}} =
             Invitations.preview_reminders(poll, actor)

    accept_initial_invitation!(poll, actor)

    assert {:ok, %{ready_count: 1, counts: %{ready_for_reminder: 1}}} =
             Invitations.preview_reminders(poll, actor)

    Ash.create!(
      Participation,
      %{poll_id: poll.id, member_id: member.id},
      action: :record,
      authorize?: false
    )

    assert {:ok, %{ready_count: 0, counts: %{already_voted: 1}}} =
             Invitations.preview_reminders(poll, actor)
  end

  test "queues ID-only reminder jobs and an aggregate audit event", %{actor: actor} do
    {poll, _member, grant} = open_poll_with_member!(actor)
    accept_initial_invitation!(poll, actor)

    assert {:ok, %{deliveries: [delivery], queued_count: 1, skipped_count: 0}} =
             Invitations.enqueue_reminders(poll, actor)

    assert delivery.kind == :reminder
    assert delivery.credential_version == grant.credential_version

    assert Enum.any?(all_enqueued(), fn job ->
             job.args == %{"delivery_id" => delivery.id}
           end)

    assert {:ok, %{ready_count: 0, counts: %{reminder_in_flight: 1}}} =
             Invitations.preview_reminders(poll, actor)

    [event] =
      Polly.Audit.Event
      |> Ash.Query.filter(action == "poll.reminders_enqueued")
      |> Ash.read!(authorize?: false)

    assert event.metadata["queued_count"] == 1
    assert event.metadata["skipped_count"] == 0
    assert event.metadata["request_kind"] == "reminder"
    refute Map.has_key?(event.metadata, "member_ids")
  end

  test "worker sends multipart reminder copy using the pinned credential", %{actor: actor} do
    {poll, member, grant} = open_poll_with_member!(actor)
    accept_initial_invitation!(poll, actor)

    assert {:ok, %{deliveries: [delivery]}} = Invitations.enqueue_reminders(poll, actor)

    assert :ok =
             InvitationWorker.perform(%Oban.Job{
               args: %{"delivery_id" => delivery.id},
               attempt: 1,
               max_attempts: 5
             })

    assert_email_sent(fn email ->
      assert email.to == [{member.name, member.email}]
      assert email.subject == "Reminder: voting is open for #{poll.title}"
      assert email.text_body =~ "you have not yet submitted a ballot"
      assert email.text_body =~ "Selection rule: Choose one."
      assert email.text_body =~ voting_token(grant)
      assert email.html_body =~ "Voting reminder"
      assert email.html_body =~ "Voting is still open"
      refute email.text_body =~ "Cedar proposal"
      refute email.text_body =~ "Quartz proposal"
      assert email.html_body =~ voting_token(grant)
    end)
  end

  test "an accepted reminder applies the cooldown", %{actor: actor} do
    {poll, _member, _grant} = open_poll_with_member!(actor)
    accept_initial_invitation!(poll, actor)

    assert {:ok, %{deliveries: [delivery]}} = Invitations.enqueue_reminders(poll, actor)
    Ash.update!(delivery, %{attempt_count: 1}, action: :accept, authorize?: false)

    assert {:ok, %{ready_count: 0, counts: %{reminder_cooldown: 1}}} =
             Invitations.preview_reminders(poll, actor)
  end

  test "reminder operations enforce authorization and the configured size limit", %{actor: actor} do
    {poll, _member, _grant} = open_poll_with_member!(actor)
    accept_initial_invitation!(poll, actor)

    auditor = %{actor | role: :auditor}
    assert {:error, :forbidden} = Invitations.preview_reminders(poll, auditor)
    assert {:error, :forbidden} = Invitations.enqueue_reminders(poll, auditor)

    previous_limit = Application.fetch_env!(:polly, :reminder_operation_limit)
    Application.put_env(:polly, :reminder_operation_limit, 0)
    on_exit(fn -> Application.put_env(:polly, :reminder_operation_limit, previous_limit) end)

    assert {:error, {:operation_limit_exceeded, 0}} =
             Invitations.enqueue_reminders(poll, actor)
  end

  test "reminder worker cancels when the member votes after queueing", %{actor: actor} do
    {poll, member, _grant} = open_poll_with_member!(actor)
    accept_initial_invitation!(poll, actor)
    assert {:ok, %{deliveries: [delivery]}} = Invitations.enqueue_reminders(poll, actor)

    Ash.create!(
      Participation,
      %{poll_id: poll.id, member_id: member.id},
      action: :record,
      authorize?: false
    )

    assert :ok =
             InvitationWorker.perform(%Oban.Job{
               args: %{"delivery_id" => delivery.id},
               attempt: 1,
               max_attempts: 5
             })

    delivery = Ash.get!(InvitationDelivery, delivery.id, actor: actor)
    assert delivery.status == :cancelled
    assert delivery.last_error_code == "already_voted"
    refute_email_sent()
  end

  test "reminder worker revalidates cooldown before delivery", %{actor: actor} do
    {poll, _member, _grant} = open_poll_with_member!(actor)
    accept_initial_invitation!(poll, actor)
    assert {:ok, %{deliveries: [queued]}} = Invitations.enqueue_reminders(poll, actor)

    accepted =
      Ash.create!(
        InvitationDelivery,
        %{
          poll_id: queued.poll_id,
          member_id: queued.member_id,
          access_grant_id: queued.access_grant_id,
          requested_by_id: actor.id,
          operation_id: Ash.UUID.generate(),
          kind: :reminder,
          dedupe_key: "reminder-race:#{Ash.UUID.generate()}",
          recipient_email: queued.recipient_email,
          credential_version: queued.credential_version
        },
        action: :queue,
        actor: actor
      )

    Ash.update!(accepted, %{attempt_count: 1}, action: :accept, authorize?: false)

    assert :ok =
             InvitationWorker.perform(%Oban.Job{
               args: %{"delivery_id" => queued.id},
               attempt: 1,
               max_attempts: 5
             })

    queued = Ash.get!(InvitationDelivery, queued.id, actor: actor)
    assert queued.status == :cancelled
    assert queued.last_error_code == "reminder_cooldown"
    refute_email_sent()
  end

  defp open_poll_with_member!(actor) do
    poll = draft_poll!(actor)

    member =
      Ash.create!(Member, %{name: "Jamie Rivera", email: "jamie@example.com"}, actor: actor)

    {_eligibility, grant} = Polly.Polls.Electorate.include_member(poll, member, actor)
    {open!(poll, actor), member, grant}
  end

  defp draft_poll!(actor) do
    poll = Ash.create!(Poll, %{title: "Board Election"}, actor: actor)
    Ash.create!(Option, %{poll_id: poll.id, label: "Cedar proposal", position: 1}, actor: actor)
    Ash.create!(Option, %{poll_id: poll.id, label: "Quartz proposal", position: 2}, actor: actor)
    poll
  end

  defp accept_initial_invitation!(poll, actor) do
    assert {:ok, [delivery]} = Invitations.enqueue_bulk(poll, actor)
    Ash.update!(delivery, %{attempt_count: 1}, action: :accept, authorize?: false)
  end

  defp open!(poll, actor), do: Ash.update!(poll, %{}, action: :open, actor: actor)
end
