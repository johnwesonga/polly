defmodule Polly.Polls.LifecycleTelemetry do
  @moduledoc """
  Emits bounded telemetry for scheduled poll lifecycle operations.

  Metadata is deliberately limited to transition kind, outcome, and a safe
  failure code. Poll, administrator, voter, credential, and job arguments are
  never included.
  """

  @event_prefix [:polly, :polls, :lifecycle]

  @doc "Emits a count when an opening or closing transition is scheduled."
  def scheduled(kind) when kind in [:open, :close] do
    :telemetry.execute(@event_prefix ++ [:scheduled], %{count: 1}, %{kind: kind})
  end

  @doc "Emits the terminal outcome and execution delay for a transition."
  def executed(transition, outcome, failure_code \\ nil)
      when outcome in [:completed, :skipped, :failed] do
    delay = max(DateTime.diff(DateTime.utc_now(), transition.scheduled_at, :millisecond), 0)

    :telemetry.execute(
      @event_prefix ++ [:executed],
      %{count: 1, delay: delay},
      %{kind: transition.kind, outcome: outcome, failure_code: failure_code}
    )
  end
end
