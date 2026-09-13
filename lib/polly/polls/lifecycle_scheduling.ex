defmodule Polly.Polls.LifecycleScheduling do
  @moduledoc """
  Configures, replaces, cancels, and lists scheduled poll lifecycle changes.

  Phase 1 persists and schedules durable transitions. The generated worker does
  not call the poll lifecycle actions until Phase 2.
  """

  require Ash.Query

  alias Polly.Accounts.Authorization
  alias Polly.Polls.{LifecycleTransition, Poll}

  @lead_time_seconds 60
  @horizon_seconds 365 * 24 * 60 * 60

  @spec schedule(Poll.t(), map(), term()) :: {:ok, LifecycleTransition.t()} | {:error, term()}
  def schedule(%Poll{} = poll, attributes, actor) when is_map(attributes) do
    kind = fetch(attributes, :kind)
    scheduled_at = fetch(attributes, :scheduled_at)

    with :ok <- authorize(actor, kind),
         {:ok, poll} <- Ash.get(Poll, poll.id, actor: actor),
         {:ok, scheduled_at} <- normalize_time(scheduled_at),
         :ok <- validate_poll_state(poll.status, kind),
         {:ok, pending} <- pending_for_poll(poll.id, actor),
         :ok <- validate_no_existing_kind(pending, kind),
         :ok <- validate_order(pending, kind, scheduled_at) do
      in_transaction(fn ->
        transition =
          create_transition!(poll, kind, scheduled_at, actor)

        schedule_worker!(transition)
        append_audit!("poll.lifecycle_scheduled", transition, poll, actor)
        Polly.Polls.LifecycleTelemetry.scheduled(kind)
        transition
      end)
    end
  end

  def schedule(_poll, _attributes, nil), do: {:error, :actor_required}
  def schedule(_poll, _attributes, _actor), do: {:error, :invalid_schedule}

  @spec replace(LifecycleTransition.t(), DateTime.t(), term()) ::
          {:ok, LifecycleTransition.t()} | {:error, term()}
  def replace(_transition, _scheduled_at, nil), do: {:error, :actor_required}

  def replace(%LifecycleTransition{} = transition, scheduled_at, actor) do
    with {:ok, transition} <- get_transition(transition.id, actor),
         :ok <- authorize(actor, transition.kind),
         :ok <- require_pending(transition),
         {:ok, poll} <- Ash.get(Poll, transition.poll_id, actor: actor),
         {:ok, scheduled_at} <- normalize_time(scheduled_at),
         :ok <- validate_poll_state(poll.status, transition.kind),
         {:ok, pending} <- pending_for_poll(poll.id, actor),
         :ok <-
           validate_order(
             Enum.reject(pending, &(&1.id == transition.id)),
             transition.kind,
             scheduled_at
           ) do
      in_transaction(fn ->
        cancel_transition!(transition)

        replacement =
          create_transition!(poll, transition.kind, scheduled_at, actor, transition.id)

        schedule_worker!(replacement)

        append_audit!("poll.lifecycle_schedule_replaced", replacement, poll, actor, %{
          previous_scheduled_for: iso8601(transition.scheduled_at),
          replaced_transition_id: transition.id
        })

        replacement
      end)
    end
  end

  def replace(_transition, _scheduled_at, _actor), do: {:error, :invalid_transition}

  @spec cancel(LifecycleTransition.t(), term()) ::
          {:ok, LifecycleTransition.t()} | {:error, term()}
  def cancel(_transition, nil), do: {:error, :actor_required}

  def cancel(%LifecycleTransition{} = transition, actor) do
    with {:ok, transition} <- get_transition(transition.id, actor),
         :ok <- authorize(actor, transition.kind),
         :ok <- require_pending(transition),
         {:ok, poll} <- Ash.get(Poll, transition.poll_id, actor: actor) do
      in_transaction(fn ->
        cancelled = cancel_transition!(transition)
        append_audit!("poll.lifecycle_schedule_cancelled", cancelled, poll, actor)
        cancelled
      end)
    end
  end

  def cancel(_transition, _actor), do: {:error, :invalid_transition}

  @spec list_for_poll(Poll.t(), term()) ::
          {:ok, [LifecycleTransition.t()]} | {:error, term()}
  def list_for_poll(_poll, nil), do: {:error, :actor_required}

  def list_for_poll(%Poll{} = poll, actor) do
    if Authorization.any_allowed?(actor, [:manage_polls, :publish_results]) do
      LifecycleTransition
      |> Ash.Query.filter(poll_id == ^poll.id)
      |> Ash.Query.sort(scheduled_at: :asc)
      |> Ash.read(actor: actor)
    else
      {:error, :forbidden}
    end
  end

  def list_for_poll(_poll, _actor), do: {:error, :invalid_poll}

  defp authorize(nil, _kind), do: {:error, :actor_required}
  defp authorize(actor, :open), do: Authorization.authorize(actor, :manage_polls)
  defp authorize(actor, :close), do: Authorization.authorize(actor, :publish_results)
  defp authorize(_actor, _kind), do: {:error, :invalid_transition_kind}

  defp validate_poll_state(:draft, :open), do: :ok

  defp validate_poll_state(status, :open) when status in [:open, :closed],
    do: {:error, :poll_not_draft}

  defp validate_poll_state(status, :close) when status in [:draft, :open], do: :ok
  defp validate_poll_state(:closed, :close), do: {:error, :poll_closed}
  defp validate_poll_state(_status, _kind), do: {:error, :invalid_poll_state}

  defp normalize_time(%DateTime{} = scheduled_at) do
    scheduled_at =
      scheduled_at
      |> DateTime.to_unix(:microsecond)
      |> DateTime.from_unix!(:microsecond)

    now = DateTime.utc_now()
    earliest = DateTime.add(now, @lead_time_seconds, :second)
    latest = DateTime.add(now, @horizon_seconds, :second)

    cond do
      DateTime.compare(scheduled_at, earliest) == :lt -> {:error, :scheduled_too_soon}
      DateTime.compare(scheduled_at, latest) == :gt -> {:error, :scheduled_too_far}
      true -> {:ok, scheduled_at}
    end
  end

  defp normalize_time(_scheduled_at), do: {:error, :invalid_scheduled_at}

  defp validate_no_existing_kind(transitions, kind) do
    if Enum.any?(transitions, &(&1.kind == kind)) do
      {:error, :transition_already_scheduled}
    else
      :ok
    end
  end

  defp validate_order(transitions, :open, scheduled_at) do
    case Enum.find(transitions, &(&1.kind == :close)) do
      nil -> :ok
      close -> before?(scheduled_at, close.scheduled_at, :opening_must_precede_closing)
    end
  end

  defp validate_order(transitions, :close, scheduled_at) do
    case Enum.find(transitions, &(&1.kind == :open)) do
      nil -> :ok
      open -> before?(open.scheduled_at, scheduled_at, :closing_must_follow_opening)
    end
  end

  defp before?(first, second, error) do
    if DateTime.compare(first, second) == :lt, do: :ok, else: {:error, error}
  end

  defp pending_for_poll(poll_id, actor) do
    LifecycleTransition
    |> Ash.Query.filter(poll_id == ^poll_id and state == :pending)
    |> Ash.read(actor: actor)
  end

  defp get_transition(id, actor), do: Ash.get(LifecycleTransition, id, actor: actor)

  defp require_pending(%LifecycleTransition{state: :pending}), do: :ok
  defp require_pending(_transition), do: {:error, :transition_not_pending}

  defp create_transition!(poll, kind, scheduled_at, actor, replaces_transition_id \\ nil) do
    LifecycleTransition
    |> Ash.Changeset.for_create(
      :schedule,
      %{
        poll_id: poll.id,
        kind: kind,
        scheduled_at: scheduled_at,
        scheduled_by_id: actor.id,
        replaces_transition_id: replaces_transition_id
      },
      authorize?: false
    )
    |> Ash.create!()
  end

  defp cancel_transition!(transition) do
    transition
    |> Ash.Changeset.for_update(:cancel, %{}, authorize?: false)
    |> Ash.update!()
  end

  defp schedule_worker!(transition) do
    AshOban.run_trigger(transition, :execute_due_transition,
      scheduled_at: transition.scheduled_at
    )
  end

  defp append_audit!(action, transition, poll, actor, additional_metadata \\ %{}) do
    Polly.Audit.append!(%{
      action: action,
      actor: actor,
      target: %{type: "poll", id: poll.id, label: poll.title},
      poll_id: poll.id,
      metadata:
        Map.merge(
          %{
            transition_kind: to_string(transition.kind),
            scheduled_for: iso8601(transition.scheduled_at)
          },
          additional_metadata
        )
    })
  end

  defp iso8601(datetime), do: DateTime.to_iso8601(datetime)

  defp in_transaction(fun) do
    case Polly.Repo.transaction(fun) do
      {:ok, result} -> {:ok, result}
      {:error, reason} -> {:error, reason}
    end
  rescue
    error -> {:error, error}
  end

  defp fetch(attributes, key), do: Map.get(attributes, key, Map.get(attributes, to_string(key)))
end
