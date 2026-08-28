defmodule Polly.Accounts.AdministratorInvitation.Status do
  @moduledoc "Lifecycle states for an administrator invitation."

  use Ash.Type.Enum, values: [:pending, :accepted, :revoked, :expired]
end
