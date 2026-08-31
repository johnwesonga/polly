defmodule PollyWeb.PollTiming do
  @moduledoc "Formats when an active poll opened and how long it has been running."

  @spec summary(DateTime.t() | nil, DateTime.t()) :: String.t()
  def summary(opened_at, now \\ DateTime.utc_now())

  def summary(nil, _now), do: "Opening time unavailable"

  def summary(%DateTime{} = opened_at, %DateTime{} = now) do
    "Opened #{format_datetime(opened_at)} · Running for #{elapsed(opened_at, now)}"
  end

  @spec publication_summary(DateTime.t() | nil) :: String.t() | nil
  def publication_summary(nil), do: nil

  def publication_summary(%DateTime{} = published_at),
    do: "Published #{format_datetime(published_at)}"

  @spec duration(DateTime.t() | nil, DateTime.t() | nil) :: String.t()
  def duration(nil, _ended_at), do: "Unavailable"
  def duration(_opened_at, nil), do: "Unavailable"
  def duration(%DateTime{} = opened_at, %DateTime{} = ended_at), do: elapsed(opened_at, ended_at)

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

  defp format_datetime(datetime),
    do: Calendar.strftime(datetime, "%b %-d, %Y at %-I:%M %p UTC")

  defp join_parts(parts) do
    parts
    |> Enum.reject(fn {value, _label} -> value == 0 end)
    |> Enum.map_join(", ", fn {value, label} -> unit(value, label) end)
  end

  defp unit(value, label), do: "#{value} #{label}#{if value == 1, do: "", else: "s"}"
end
