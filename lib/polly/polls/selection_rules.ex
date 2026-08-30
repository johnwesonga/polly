defmodule Polly.Polls.SelectionRules do
  @moduledoc "Provides consistent, plain-language descriptions of poll selection rules."

  alias Polly.Polls.Poll

  @doc "Returns a concise rule summary suitable for poll lists and detail headers."
  @spec summary(Poll.t()) :: String.t()
  def summary(%Poll{selection_mode: :single}), do: "Choose one"

  def summary(%Poll{
        selection_mode: :multiple,
        minimum_selections: count,
        maximum_selections: count
      }),
      do: "Choose exactly #{count}"

  def summary(%Poll{
        selection_mode: :multiple,
        minimum_selections: 1,
        maximum_selections: maximum
      }),
      do: "Choose up to #{maximum}"

  def summary(%Poll{
        selection_mode: :multiple,
        minimum_selections: minimum,
        maximum_selections: maximum
      }),
      do: "Choose #{minimum}–#{maximum}"
end
