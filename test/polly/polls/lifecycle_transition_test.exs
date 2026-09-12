defmodule Polly.Polls.LifecycleTransitionTest do
  use Polly.DataCase, async: false
  use Oban.Testing, repo: Polly.Repo

  alias Polly.Polls.LifecycleTransition

  test "a due transition is completed by the generated AshOban worker" do
    transition = create_transition!(DateTime.add(DateTime.utc_now(), -60, :second))

    job =
      AshOban.run_trigger(transition, :execute_due_transition,
        scheduled_at: transition.scheduled_at
      )

    assert job.worker == "Polly.Polls.LifecycleTransitionWorker"
    assert job.queue == "poll_lifecycle"
    assert job.args[:primary_key] == %{id: transition.id}
    refute Map.has_key?(job.args, :actor)
    refute inspect(job.args) =~ "poll"

    assert %{success: 1, failure: 0} =
             Oban.drain_queue(
               queue: :poll_lifecycle,
               with_scheduled: DateTime.utc_now()
             )

    completed = Ash.reload!(transition, authorize?: false)
    assert completed.state == :completed
    assert %DateTime{} = completed.completed_at
  end

  test "a future transition remains scheduled" do
    transition = create_transition!(DateTime.add(DateTime.utc_now(), 3_600, :second))

    job =
      AshOban.run_trigger(transition, :execute_due_transition,
        scheduled_at: transition.scheduled_at
      )

    assert job.state == "scheduled"
    assert %{success: 0, failure: 0} = Oban.drain_queue(queue: :poll_lifecycle)
    assert Ash.reload!(transition, authorize?: false).state == :pending
  end

  test "a job cannot complete a transition that is no longer pending" do
    transition = create_transition!(DateTime.add(DateTime.utc_now(), -60, :second))
    job = AshOban.run_trigger(transition, :execute_due_transition)

    transition
    |> Ash.Changeset.for_update(:complete_proof_of_concept, %{}, authorize?: false)
    |> Ash.update!()

    assert {:cancel, :trigger_no_longer_applies} =
             perform_job(Polly.Polls.LifecycleTransitionWorker, job.args)

    completed = Ash.reload!(transition, authorize?: false)
    assert completed.state == :completed
  end

  defp create_transition!(scheduled_at) do
    LifecycleTransition
    |> Ash.Changeset.for_create(
      :create_proof_of_concept,
      %{scheduled_at: scheduled_at},
      authorize?: false
    )
    |> Ash.create!()
  end
end
