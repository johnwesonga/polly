defmodule Polly.Members.MemberImport.Row do
  @moduledoc "A normalized row in a member import preview."

  @enforce_keys [:row_number, :name, :email, :classification, :errors]
  defstruct [:row_number, :name, :email, :classification, :existing_name, errors: []]

  @type t :: %__MODULE__{
          row_number: pos_integer(),
          name: String.t(),
          email: String.t(),
          classification: :new | :existing | :invalid,
          existing_name: String.t() | nil,
          errors: [String.t()]
        }
end
