defmodule Polly.Polls.Slug do
  @moduledoc false

  require Ash.Query

  alias Polly.Polls.Poll

  @max_length 180
  @max_attempts 100

  def from_title(title) do
    title
    |> String.normalize(:nfd)
    |> String.replace(~r/[^\p{L}\p{N}\s-]/u, "")
    |> String.downcase()
    |> String.replace(~r/[\s_-]+/u, "-")
    |> String.trim("-")
  end

  def unique_from_title(title, excluding_id \\ nil) do
    Enum.find_value(1..@max_attempts, fn attempt ->
      candidate = candidate_for_title(title, attempt)
      if available?(candidate, excluding_id), do: candidate
    end)
  end

  def candidate_for_title(title, attempt) when attempt >= 1 do
    suffix = if attempt == 1, do: "", else: "-#{attempt}"

    title
    |> from_title()
    |> String.slice(0, @max_length - String.length(suffix))
    |> String.trim_trailing("-")
    |> Kernel.<>(suffix)
  end

  defp available?(candidate, excluding_id) do
    query = Ash.Query.filter(Poll, slug == ^candidate)

    query =
      if excluding_id do
        Ash.Query.filter(query, id != ^excluding_id)
      else
        query
      end

    not Ash.exists?(query, authorize?: false)
  end
end
