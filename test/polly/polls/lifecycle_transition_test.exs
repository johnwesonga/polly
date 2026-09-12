defmodule Polly.Polls.LifecycleTransitionTest do
  use Polly.DataCase, async: false
  use Oban.Testing, repo: Polly.Repo

  require Ash.Query

  alias Polly.Accounts.User
  alias Polly.Audit.Event
  alias Polly.Polls.{LifecycleScheduling, LifecycleTransition, Poll}

  setup do
    actor = create_user!(:administrator)
    poll = Ash.create!(Poll, %{title: "Scheduled poll"}, actor: actor)
    %{actor: actor, poll: poll}
  end

  test "schedules a future opening with an ID-only generated job", %{actor: actor, poll: poll} do
    scheduled_at = future_time(2)

    assert {:ok, transition} =
             LifecycleScheduling.schedule(
               poll,
               %{kind: :open, scheduled_at: scheduled_at},
               actor
             )

    assert transition.poll_id == poll.id
    assert transition.scheduled_by_id == actor.id
    assert transition.kind == :open
    assert transition.state == :pending
    assert transition.scheduled_at == scheduled_at

    assert [%Oban.Job{} = job] =
             all_enqueued(worker: Polly.Polls.LifecycleTransitionWorker)

    assert job.queue == "poll_lifecycle"
    assert job.args["primary_key"] == %{"id" => transition.id}
    refute Map.has_key?(job.args, "actor")
    refute inspect(job.args) =~ poll.id

    assert %Event{action: "poll.lifecycle_scheduled"} =
             audit_event!(transition.poll_id, "poll.lifecycle_scheduled")
  end

  test "allows a draft closing schedule and orders it after a pending opening", %{
    actor: actor,
    poll: poll
  } do
    opening_at = future_time(2)
    closing_at = future_time(3)

    assert {:ok, opening} =
             LifecycleScheduling.schedule(poll, %{kind: :open, scheduled_at: opening_at}, actor)

    assert {:ok, closing} =
             LifecycleScheduling.schedule(poll, %{kind: :close, scheduled_at: closing_at}, actor)

    assert opening.kind == :open
    assert closing.kind == :close

    assert {:error, :transition_already_scheduled} =
             LifecycleScheduling.schedule(
               poll,
               %{kind: :close, scheduled_at: future_time(4)},
               actor
             )
  end

  test "rejects invalid times and reversed opening and closing order", %{
    actor: actor,
    poll: poll
  } do
    assert {:error, :scheduled_too_soon} =
             LifecycleScheduling.schedule(
               poll,
               %{kind: :open, scheduled_at: DateTime.utc_now()},
               actor
             )

    assert {:error, :scheduled_too_far} =
             LifecycleScheduling.schedule(
               poll,
               %{kind: :open, scheduled_at: future_time(24 * 366)},
               actor
             )

    assert {:ok, _closing} =
             LifecycleScheduling.schedule(
               poll,
               %{kind: :close, scheduled_at: future_time(2)},
               actor
             )

    assert {:error, :opening_must_precede_closing} =
             LifecycleScheduling.schedule(
               poll,
               %{kind: :open, scheduled_at: future_time(3)},
               actor
             )
  end

  test "rejects schedules for a closed poll", %{actor: actor, poll: poll} do
    Polly.Repo.query!("UPDATE polls SET status = 'closed' WHERE id = ?", [poll.id])
    closed = Ash.get!(Poll, poll.id, actor: actor)

    assert {:error, :poll_not_draft} =
             LifecycleScheduling.schedule(
               closed,
               %{kind: :open, scheduled_at: future_time(2)},
               actor
             )

    assert {:error, :poll_closed} =
             LifecycleScheduling.schedule(
               closed,
               %{kind: :close, scheduled_at: future_time(2)},
               actor
             )
  end

  test "replaces a pending schedule and leaves the old job stale", %{actor: actor, poll: poll} do
    assert {:ok, original} =
             LifecycleScheduling.schedule(
               poll,
               %{kind: :open, scheduled_at: future_time(2)},
               actor
             )

    assert {:ok, replacement} =
             LifecycleScheduling.replace(original, future_time(3), actor)

    assert replacement.id != original.id
    assert replacement.replaces_transition_id == original.id
    assert replacement.state == :pending

    original = Ash.reload!(original, authorize?: false)
    assert original.state == :cancelled
    assert %DateTime{} = original.cancelled_at

    original_job =
      all_enqueued(worker: Polly.Polls.LifecycleTransitionWorker)
      |> Enum.find(&(&1.args["primary_key"]["id"] == original.id))

    assert {:cancel, :trigger_no_longer_applies} =
             perform_job(Polly.Polls.LifecycleTransitionWorker, original_job.args)

    assert %Event{action: "poll.lifecycle_schedule_replaced"} =
             audit_event!(poll.id, "poll.lifecycle_schedule_replaced")
  end

  test "cancels a pending schedule and preserves it as history", %{actor: actor, poll: poll} do
    assert {:ok, transition} =
             LifecycleScheduling.schedule(
               poll,
               %{kind: :close, scheduled_at: future_time(2)},
               actor
             )

    assert {:ok, cancelled} = LifecycleScheduling.cancel(transition, actor)
    assert cancelled.id == transition.id
    assert cancelled.state == :cancelled
    assert %DateTime{} = cancelled.cancelled_at

    assert {:error, :transition_not_pending} = LifecycleScheduling.cancel(cancelled, actor)

    assert %Event{action: "poll.lifecycle_schedule_cancelled"} =
             audit_event!(poll.id, "poll.lifecycle_schedule_cancelled")
  end

  test "lists transition history in scheduled order", %{actor: actor, poll: poll} do
    assert {:ok, later} =
             LifecycleScheduling.schedule(
               poll,
               %{kind: :close, scheduled_at: future_time(4)},
               actor
             )

    assert {:ok, earlier} =
             LifecycleScheduling.schedule(
               poll,
               %{kind: :open, scheduled_at: future_time(2)},
               actor
             )

    assert {:ok, transitions} = LifecycleScheduling.list_for_poll(poll, actor)
    assert Enum.map(transitions, & &1.id) == [earlier.id, later.id]
  end

  test "requires the permission associated with lifecycle configuration", %{poll: poll} do
    operator = create_user!(:operator)

    assert {:error, :forbidden} =
             LifecycleScheduling.schedule(
               poll,
               %{kind: :open, scheduled_at: future_time(2)},
               operator
             )

    assert {:error, :forbidden} = LifecycleScheduling.list_for_poll(poll, operator)
    assert {:error, :actor_required} = LifecycleScheduling.list_for_poll(poll, nil)
  end

  test "the Phase 1 worker remains harmless to the poll", %{actor: actor, poll: poll} do
    transition = create_transition!(poll, actor, DateTime.add(DateTime.utc_now(), -60, :second))

    _job =
      AshOban.run_trigger(transition, :execute_due_transition,
        scheduled_at: transition.scheduled_at
      )

    assert %{success: 1, failure: 0} =
             Oban.drain_queue(queue: :poll_lifecycle, with_scheduled: DateTime.utc_now())

    assert Ash.reload!(transition, authorize?: false).state == :completed
    assert Ash.reload!(poll, authorize?: false).status == :draft
  end

  defp create_transition!(poll, actor, scheduled_at) do
    LifecycleTransition
    |> Ash.Changeset.for_create(
      :schedule,
      %{
        poll_id: poll.id,
        kind: :open,
        scheduled_at: scheduled_at,
        scheduled_by_id: actor.id
      },
      authorize?: false
    )
    |> Ash.create!()
  end

  defp audit_event!(poll_id, action) do
    Event
    |> Ash.Query.filter(poll_id == ^poll_id and action == ^action)
    |> Ash.Query.sort(inserted_at: :desc)
    |> Ash.read_one!(authorize?: false)
  end

  defp create_user!(role) do
    Ash.create!(
      User,
      %{
        email: "lifecycle-#{role}-#{System.unique_integer([:positive])}@example.com",
        password: "secure-password",
        password_confirmation: "secure-password",
        role: role
      },
      action: :register_with_password,
      authorize?: false
    )
  end

  defp future_time(hours) do
    DateTime.utc_now()
    |> DateTime.add(hours * 60 * 60, :second)
    |> DateTime.truncate(:microsecond)
  end
end
