defmodule Polly.Accounts.User.Role do
  @moduledoc """
  Defines the fixed administrator roles supported by Polly.

  Role permissions are introduced in a later administrator-management phase.
  """

  use Ash.Type.Enum, values: [:owner, :administrator, :auditor, :operator]
end
