defmodule Polly.Polls.Slug do
  @moduledoc false

  def from_title(title) do
    title
    |> String.normalize(:nfd)
    |> String.replace(~r/[^\p{L}\p{N}\s-]/u, "")
    |> String.downcase()
    |> String.replace(~r/[\s_-]+/u, "-")
    |> String.trim("-")
  end
end
