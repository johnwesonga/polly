defmodule Polly.Polls.SelectionRulesTest do
  use ExUnit.Case, async: true

  alias Polly.Polls.{Poll, SelectionRules}

  test "describes single and multiple selection ranges" do
    assert SelectionRules.summary(poll(:single, 1, 1)) == "Choose one"
    assert SelectionRules.summary(poll(:multiple, 1, 3)) == "Choose up to 3"
    assert SelectionRules.summary(poll(:multiple, 3, 3)) == "Choose exactly 3"
    assert SelectionRules.summary(poll(:multiple, 2, 5)) == "Choose 2–5"
  end

  defp poll(mode, minimum, maximum) do
    %Poll{
      selection_mode: mode,
      minimum_selections: minimum,
      maximum_selections: maximum
    }
  end
end
