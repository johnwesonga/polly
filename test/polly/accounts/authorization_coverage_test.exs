defmodule Polly.Accounts.AuthorizationCoverageTest do
  use ExUnit.Case, async: true

  alias Polly.Accounts.AuthorizationCoverage

  test "every current Ash action has an intended authorization boundary" do
    inventory = AuthorizationCoverage.resource_actions()

    actual =
      Map.new(inventory, fn {resource, _actions} ->
        actions = resource |> Ash.Resource.Info.actions() |> Enum.map(& &1.name) |> MapSet.new()
        {resource, actions}
      end)

    expected =
      Map.new(inventory, fn {resource, actions} ->
        {resource, actions |> Map.keys() |> MapSet.new()}
      end)

    assert actual == expected
  end

  test "all boundary classifications use the centralized permission vocabulary" do
    known_permissions = MapSet.new(AuthorizationCoverage.permissions())

    classifications =
      AuthorizationCoverage.web_boundaries()
      |> Map.values()
      |> Kernel.++(Map.values(AuthorizationCoverage.service_boundaries()))
      |> Kernel.++(
        AuthorizationCoverage.resource_actions()
        |> Map.values()
        |> Enum.flat_map(&Map.values/1)
      )

    Enum.each(classifications, &assert_valid_classification(&1, known_permissions))
  end

  test "every authorization bypass remains explicitly reviewed" do
    actual =
      "lib/**/*.ex"
      |> Path.wildcard()
      |> Enum.reject(&(&1 == "lib/polly/accounts/authorization_coverage.ex"))
      |> Enum.reduce(%{}, fn path, counts ->
        count = path |> File.read!() |> count_occurrences("authorize?: false")

        if count == 0, do: counts, else: Map.put(counts, path, count)
      end)

    expected =
      Map.new(AuthorizationCoverage.authorization_bypasses(), fn {path, review} ->
        assert is_binary(review.reason) and review.reason != ""
        {path, review.count}
      end)

    assert actual == expected
  end

  defp assert_valid_classification({:permission, permission}, known) do
    assert permission in known
  end

  defp assert_valid_classification({:any, permissions}, known) do
    assert permissions != []
    assert MapSet.subset?(MapSet.new(permissions), known)
  end

  defp assert_valid_classification({:all, permissions, options}, known) do
    assert permissions != []
    assert MapSet.subset?(MapSet.new(permissions), known)

    options
    |> Keyword.get(:event_permissions, [])
    |> Keyword.values()
    |> Enum.each(&assert(&1 in known))
  end

  defp assert_valid_classification({:trusted, reason}, _known) do
    assert is_binary(reason) and reason != ""
  end

  defp count_occurrences(contents, needle) do
    contents
    |> :binary.matches(needle)
    |> length()
  end
end
