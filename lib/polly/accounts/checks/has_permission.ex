defmodule Polly.Accounts.Checks.HasPermission do
  @moduledoc false

  use Ash.Policy.SimpleCheck

  alias Polly.Accounts.Authorization

  @impl true
  def describe(options),
    do: "actor has one of #{inspect(options[:permissions] || options[:permission])}"

  @impl true
  def match?(actor, _context, options) do
    permissions = options |> Keyword.get(:permissions, options[:permission]) |> List.wrap()
    Authorization.any_allowed?(actor, permissions)
  end
end
