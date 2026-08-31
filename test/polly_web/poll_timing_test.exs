defmodule PollyWeb.PollTimingTest do
  use ExUnit.Case, async: true

  alias PollyWeb.PollTiming

  test "formats minute, hour, and day durations" do
    now = ~U[2026-08-31 12:00:00Z]

    assert PollTiming.elapsed(~U[2026-08-31 11:59:40Z], now) == "less than a minute"
    assert PollTiming.elapsed(~U[2026-08-31 11:42:00Z], now) == "18 minutes"
    assert PollTiming.elapsed(~U[2026-08-31 09:45:00Z], now) == "2 hours, 15 minutes"
    assert PollTiming.elapsed(~U[2026-08-29 08:00:00Z], now) == "2 days, 4 hours"
  end

  test "formats an opened summary and handles missing or future timestamps" do
    now = ~U[2026-08-31 12:00:00Z]

    assert PollTiming.summary(~U[2026-08-31 10:00:00Z], now) ==
             "Opened Aug 31, 2026 at 10:00 AM UTC · Running for 2 hours"

    assert PollTiming.summary(nil, now) == "Opening time unavailable"
    assert PollTiming.elapsed(~U[2026-08-31 13:00:00Z], now) == "less than a minute"
  end
end
