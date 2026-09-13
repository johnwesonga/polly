defmodule Polly.Polls.Changes.FailLifecycleTransition do
  @moduledoc "Records a safe terminal failure after AshOban exhausts retries."

  use Ash.Resource.Change

  alias Polly.Accounts.User
  alias Polly.Polls.Poll

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.before_action(changeset, fn changeset ->
      transition = changeset.data
      poll = Ash.get!(Poll, transition.poll_id, authorize?: false)
      configuring_actor = Ash.get!(User, transition.scheduled_by_id, authorize?: false)

      Polly.Audit.append_scheduled!(%{
        action: "poll.lifecycle_schedule_failed",
        actor: configuring_actor,
        target: %{type: "poll", id: poll.id, label: poll.title},
        poll_id: poll.id,
        metadata: %{
          transition_kind: to_string(transition.kind),
          scheduled_for: DateTime.to_iso8601(transition.scheduled_at),
          failure_code: "transition_failed"
        }
      })

      Polly.Polls.LifecycleTelemetry.executed(transition, :failed, :transition_failed)

      Ash.Changeset.force_change_attributes(changeset, %{
        state: :failed,
        failure_code: "transition_failed"
      })
    end)
  end
end
