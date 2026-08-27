defmodule Polly.Accounts.User.Status do
  @moduledoc """
  Defines whether an administrator account may be used to access Polly.

  Authentication enforcement for disabled accounts is introduced in phase 2.
  """

  use Ash.Type.Enum, values: [:active, :disabled]
end
