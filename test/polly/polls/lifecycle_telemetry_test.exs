defmodule Polly.Polls.LifecycleTelemetryTest do
  use ExUnit.Case, async: true

  alias Polly.Polls.LifecycleTelemetry

  test "emits bounded scheduling metadata" do
    handler = attach([:polly, :polls, :lifecycle, :scheduled])
    LifecycleTelemetry.scheduled(:open)

    assert_receive {:telemetry, %{count: 1}, %{kind: :open}}
    :telemetry.detach(handler)
  end

  test "emits outcome and non-negative delay without record identifiers" do
    handler = attach([:polly, :polls, :lifecycle, :executed])

    LifecycleTelemetry.executed(
      %{kind: :close, scheduled_at: DateTime.add(DateTime.utc_now(), -30, :second)},
      :failed,
      :poll_not_open
    )

    assert_receive {:telemetry, %{count: 1, delay: delay}, metadata}
    assert delay >= 0
    assert metadata == %{kind: :close, outcome: :failed, failure_code: :poll_not_open}
    refute Map.has_key?(metadata, :poll_id)
    refute Map.has_key?(metadata, :transition_id)
    :telemetry.detach(handler)
  end

  defp attach(event) do
    id = "lifecycle-telemetry-#{System.unique_integer([:positive])}"
    test = self()

    :ok =
      :telemetry.attach(
        id,
        event,
        fn _event, measurements, metadata, _config ->
          send(test, {:telemetry, measurements, metadata})
        end,
        nil
      )

    id
  end
end
