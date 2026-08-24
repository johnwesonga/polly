defmodule Polly.Members.MemberImport.Preview do
  @moduledoc "A complete, non-persistent preview of a CSV member import."

  @enforce_keys [:rows, :total_count, :new_count, :existing_count, :invalid_count]
  defstruct [:rows, :total_count, :new_count, :existing_count, :invalid_count]

  @type t :: %__MODULE__{
          rows: [Polly.Members.MemberImport.Row.t()],
          total_count: non_neg_integer(),
          new_count: non_neg_integer(),
          existing_count: non_neg_integer(),
          invalid_count: non_neg_integer()
        }

  def valid?(%__MODULE__{invalid_count: 0}), do: true
  def valid?(%__MODULE__{}), do: false
end
