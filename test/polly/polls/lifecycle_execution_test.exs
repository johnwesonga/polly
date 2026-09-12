defmodule Polly.Polls.LifecycleExecutionTest do
  use Polly.DataCase, async: false
  use Oban.Testing, repo: Polly.Repo

  require Ash.Query

  alias Polly.Accounts.User
  alias Polly.Audit.Event
  alias Polly.Members.Member
  alias Polly.Polls.{Eligibility, LifecycleTransition, Option, Poll}

  setup do
    actor = create_user!()
    poll = Ash.create!(Poll, %{title: "Scheduled execution"}, actor: actor)
    %{actor: actor, poll: poll}
  end

  test "opens a ready poll and records its automatic outcome", %{actor: actor, poll: poll} do
    configure_poll!(poll, actor)
    transition = create_transition!(poll, actor, :open)
    Polly.Polls.Events.subscribe(poll.id)

    job = AshOban.run_trigger(transition, :execute_due_transition)

    assert {:ok, %LifecycleTransition{}} =
             perform_job(Polly.Polls.LifecycleTransitionWorker, job.args)

    opened = Ash.reload!(poll, authorize?: false)
    completed = Ash.reload!(transition, authorize?: false)

    assert opened.status == :open
    assert %DateTime{} = opened.opened_at
    assert completed.state == :completed
    assert %DateTime{} = completed.completed_at
    assert completed.failure_code == nil

    assert_receive {:poll_status_changed, poll_id, :open, nil}
    assert poll_id == poll.id

    event = audit_event!(poll.id, "poll.opened_automatically")
    assert event.source == "scheduled_job"
    assert event.actor_id == actor.id
    assert event.metadata["transition_kind"] == "open"
    assert event.metadata["scheduled_for"]
    assert event.metadata["actual_at"]

    refute audit_event(poll.id, "poll.opened")
  end

  test "closes an open poll without publishing its results", %{actor: actor, poll: poll} do
    configure_poll!(poll, actor)
    opened = Ash.update!(poll, %{}, action: :open, actor: actor)
    transition = create_transition!(opened, actor, :close)
    Polly.Polls.Events.subscribe(poll.id)

    job = AshOban.run_trigger(transition, :execute_due_transition)

    assert {:ok, %LifecycleTransition{}} =
             perform_job(Polly.Polls.LifecycleTransitionWorker, job.args)

    closed = Ash.reload!(poll, authorize?: false)
    completed = Ash.reload!(transition, authorize?: false)

    assert closed.status == :closed
    assert %DateTime{} = closed.closed_at
    assert closed.results_published_at == nil
    assert completed.state == :completed

    assert_receive {:poll_status_changed, poll_id, :closed, nil}
    assert poll_id == poll.id
    assert audit_event!(poll.id, "poll.closed_automatically").source == "scheduled_job"
    refute audit_event(poll.id, "poll.closed")
  end

  test "records a deterministic readiness failure without retrying", %{actor: actor, poll: poll} do
    transition = create_transition!(poll, actor, :open)
    job = AshOban.run_trigger(transition, :execute_due_transition)

    assert {:ok, %LifecycleTransition{}} =
             perform_job(Polly.Polls.LifecycleTransitionWorker, job.args)

    failed = Ash.reload!(transition, authorize?: false)
    assert failed.state == :failed
    assert failed.failure_code == "insufficient_options"
    assert Ash.reload!(poll, authorize?: false).status == :draft

    event = audit_event!(poll.id, "poll.lifecycle_schedule_failed")
    assert event.metadata["failure_code"] == "insufficient_options"
    refute inspect(event.metadata) =~ "Ash.Error"
  end

  test "records missing electorate separately after option readiness passes", %{
    actor: actor,
    poll: poll
  } do
    create_options!(poll, actor)
    transition = create_transition!(poll, actor, :open)
    job = AshOban.run_trigger(transition, :execute_due_transition)

    assert {:ok, %LifecycleTransition{}} =
             perform_job(Polly.Polls.LifecycleTransitionWorker, job.args)

    failed = Ash.reload!(transition, authorize?: false)
    assert failed.state == :failed
    assert failed.failure_code == "no_eligible_members"
  end

  test "skips an opening made inapplicable by a manual opening", %{actor: actor, poll: poll} do
    configure_poll!(poll, actor)
    transition = create_transition!(poll, actor, :open)
    job = AshOban.run_trigger(transition, :execute_due_transition)

    _opened = Ash.update!(poll, %{}, action: :open, actor: actor)

    assert {:ok, %LifecycleTransition{}} =
             perform_job(Polly.Polls.LifecycleTransitionWorker, job.args)

    skipped = Ash.reload!(transition, authorize?: false)
    assert skipped.state == :skipped
    assert skipped.failure_code == "poll_not_draft"
    assert Ash.reload!(poll, authorize?: false).status == :open

    event = audit_event!(poll.id, "poll.lifecycle_schedule_skipped")
    assert event.metadata["failure_code"] == "poll_not_draft"
  end

  test "skips closing when the poll never opened", %{actor: actor, poll: poll} do
    transition = create_transition!(poll, actor, :close)
    job = AshOban.run_trigger(transition, :execute_due_transition)

    assert {:ok, %LifecycleTransition{}} =
             perform_job(Polly.Polls.LifecycleTransitionWorker, job.args)

    skipped = Ash.reload!(transition, authorize?: false)
    assert skipped.state == :skipped
    assert skipped.failure_code == "poll_not_open"
    assert Ash.reload!(poll, authorize?: false).status == :draft
  end

  test "a completed transition cannot execute twice", %{actor: actor, poll: poll} do
    configure_poll!(poll, actor)
    transition = create_transition!(poll, actor, :open)
    job = AshOban.run_trigger(transition, :execute_due_transition)

    assert {:ok, %LifecycleTransition{}} =
             perform_job(Polly.Polls.LifecycleTransitionWorker, job.args)

    assert {:cancel, :trigger_no_longer_applies} =
             perform_job(Polly.Polls.LifecycleTransitionWorker, job.args)

    assert Ash.reload!(poll, authorize?: false).status == :open
    assert count_audit_events(poll.id, "poll.opened_automatically") == 1
  end

  test "execution survives the configuring administrator being disabled", %{
    actor: actor,
    poll: poll
  } do
    configure_poll!(poll, actor)
    transition = create_transition!(poll, actor, :open)
    job = AshOban.run_trigger(transition, :execute_due_transition)
    Polly.Repo.query!("UPDATE users SET status = 'disabled' WHERE id = ?", [actor.id])

    assert {:ok, %LifecycleTransition{}} =
             perform_job(Polly.Polls.LifecycleTransitionWorker, job.args)

    assert Ash.reload!(poll, authorize?: false).status == :open
    event = audit_event!(poll.id, "poll.opened_automatically")
    assert event.actor_id == actor.id
    assert event.actor_label == to_string(actor.email)
  end

  test "the final-error action stores only a bounded failure code", %{actor: actor, poll: poll} do
    transition = create_transition!(poll, actor, :open)

    failed =
      Ash.update!(
        transition,
        %{error: RuntimeError.exception("provider details must not persist")},
        action: :execution_failed,
        authorize?: false
      )

    assert failed.state == :failed
    assert failed.failure_code == "transition_failed"

    event = audit_event!(poll.id, "poll.lifecycle_schedule_failed")
    assert event.metadata["failure_code"] == "transition_failed"
    refute inspect(event) =~ "provider details must not persist"
  end

  defp configure_poll!(poll, actor) do
    create_options!(poll, actor)

    member =
      Ash.create!(
        Member,
        %{
          name: "Scheduled voter",
          email: "scheduled-voter-#{System.unique_integer([:positive])}@example.com"
        },
        actor: actor
      )

    Ash.create!(Eligibility, %{poll_id: poll.id, member_id: member.id}, actor: actor)
  end

  defp create_options!(poll, actor) do
    Ash.create!(Option, %{poll_id: poll.id, label: "First", position: 1}, actor: actor)
    Ash.create!(Option, %{poll_id: poll.id, label: "Second", position: 2}, actor: actor)
  end

  defp create_transition!(poll, actor, kind) do
    LifecycleTransition
    |> Ash.Changeset.for_create(
      :schedule,
      %{
        poll_id: poll.id,
        kind: kind,
        scheduled_at: DateTime.add(DateTime.utc_now(), -60, :second),
        scheduled_by_id: actor.id
      },
      authorize?: false
    )
    |> Ash.create!()
  end

  defp audit_event!(poll_id, action),
    do: audit_event(poll_id, action) || flunk("missing audit event")

  defp audit_event(poll_id, event_action) do
    Event
    |> Ash.Query.filter(poll_id == ^poll_id and action == ^event_action)
    |> Ash.Query.sort(inserted_at: :desc)
    |> Ash.read_one!(authorize?: false)
  end

  defp count_audit_events(poll_id, event_action) do
    Event
    |> Ash.Query.filter(poll_id == ^poll_id and action == ^event_action)
    |> Ash.count!(authorize?: false)
  end

  defp create_user! do
    Ash.create!(
      User,
      %{
        email: "execution-admin-#{System.unique_integer([:positive])}@example.com",
        password: "secure-password",
        password_confirmation: "secure-password",
        role: :administrator
      },
      action: :register_with_password,
      authorize?: false
    )
  end
end
