defmodule PollyWeb.PollTiming do
  @moduledoc "Formats when an active poll opened and how long it has been running."

  @spec summary(DateTime.t() | nil, DateTime.t()) :: String.t()
  def summary(opened_at, now \\ DateTime.utc_now())

  def summary(nil, _now), do: "Opening time unavailable"

  def summary(%DateTime{} = opened_at, %DateTime{} = now) do
    "Opened #{format_date(opened_at)} · Running for #{elapsed(opened_at, now)}"
  end

  @spec elapsed(DateTime.t(), DateTime.t()) :: String.t()
  def elapsed(%DateTime{} = opened_at, %DateTime{} = now) do
    seconds = max(DateTime.diff(now, opened_at, :second), 0)
    days = div(seconds, 86_400)
    hours = seconds |> rem(86_400) |> div(3_600)
    minutes = seconds |> rem(3_600) |> div(60)

    cond do
      days > 0 -> join_parts([{days, "day"}, {hours, "hour"}])
      hours > 0 -> join_parts([{hours, "hour"}, {minutes, "minute"}])
      minutes > 0 -> unit(minutes, "minute")
      true -> "less than a minute"
    end
  end

  defp format_date(datetime), do: Calendar.strftime(datetime, "%b %-d, %Y at %-I:%M %p UTC")

  defp join_parts(parts) do
    parts
    |> Enum.reject(fn {value, _label} -> value == 0 end)
    |> Enum.map_join(", ", fn {value, label} -> unit(value, label) end)
  end

  defp unit(value, label), do: "#{value} #{label}#{if value == 1, do: "", else: "s"}"
end
