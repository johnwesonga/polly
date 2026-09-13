defmodule Polly.Polls.Changes.ExecuteLifecycleTransition do
  @moduledoc "Executes a pending scheduled transition through the poll's lifecycle actions."

  use Ash.Resource.Change

  alias Polly.Accounts.User
  alias Polly.Polls.Poll

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.before_action(changeset, fn changeset ->
      transition = changeset.data
      poll = Ash.get!(Poll, transition.poll_id, authorize?: false)
      configuring_actor = Ash.get!(User, transition.scheduled_by_id, authorize?: false)

      case execute(poll, transition.kind, configuring_actor) do
        {:completed, updated_poll} ->
          completed_at = DateTime.utc_now()

          append_outcome!(
            automatic_action(transition.kind),
            transition,
            updated_poll,
            configuring_actor,
            %{actual_at: DateTime.to_iso8601(completed_at)}
          )

          Polly.Polls.LifecycleTelemetry.executed(transition, :completed)

          Ash.Changeset.force_change_attributes(changeset, %{
            state: :completed,
            completed_at: completed_at,
            failure_code: nil
          })

        {:skipped, code} ->
          append_non_success!(
            "poll.lifecycle_schedule_skipped",
            transition,
            poll,
            configuring_actor,
            code
          )

          Polly.Polls.LifecycleTelemetry.executed(transition, :skipped, code)

          Ash.Changeset.force_change_attributes(changeset, %{
            state: :skipped,
            failure_code: to_string(code)
          })

        {:failed, code} ->
          append_non_success!(
            "poll.lifecycle_schedule_failed",
            transition,
            poll,
            configuring_actor,
            code
          )

          Polly.Polls.LifecycleTelemetry.executed(transition, :failed, code)

          Ash.Changeset.force_change_attributes(changeset, %{
            state: :failed,
            failure_code: to_string(code)
          })
      end
    end)
  end

  defp execute(%Poll{status: :draft} = poll, :open, actor) do
    case Ash.update(poll, %{},
           action: :open,
           actor: actor,
           authorize?: false,
           context: %{audit: :skip}
         ) do
      {:ok, opened} -> {:completed, opened}
      {:error, error} -> classify_open_failure(error)
    end
  end

  defp execute(%Poll{}, :open, _actor), do: {:skipped, :poll_not_draft}

  defp execute(%Poll{status: :open} = poll, :close, actor) do
    case Ash.update(poll, %{},
           action: :close,
           actor: actor,
           authorize?: false,
           context: %{audit: :skip}
         ) do
      {:ok, closed} -> {:completed, closed}
      {:error, error} -> raise error
    end
  end

  defp execute(%Poll{}, :close, _actor), do: {:skipped, :poll_not_open}

  defp classify_open_failure(error) do
    message = Exception.message(error)

    cond do
      String.contains?(message, "at least two active options") ->
        {:failed, :insufficient_options}

      String.contains?(message, "at least one member is eligible") ->
        {:failed, :no_eligible_members}

      String.contains?(message, "cannot exceed the") ->
        {:failed, :selection_limits_invalid}

      String.contains?(message, "single-choice polls") or
          String.contains?(message, "minimum selections") ->
        {:failed, :selection_rules_invalid}

      true ->
        raise error
    end
  end

  defp append_non_success!(action, transition, poll, actor, code) do
    append_outcome!(
      action,
      transition,
      poll,
      actor,
      %{failure_code: to_string(code)}
    )
  end

  defp automatic_action(:open), do: "poll.opened_automatically"
  defp automatic_action(:close), do: "poll.closed_automatically"

  defp append_outcome!(action, transition, poll, actor, additional_metadata) do
    Polly.Audit.append_scheduled!(%{
      action: action,
      actor: actor,
      target: %{type: "poll", id: poll.id, label: poll.title},
      poll_id: poll.id,
      metadata:
        Map.merge(
          %{
            transition_kind: to_string(transition.kind),
            scheduled_for: DateTime.to_iso8601(transition.scheduled_at)
          },
          additional_metadata
        )
    })
  end
end
