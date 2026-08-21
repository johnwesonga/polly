defmodule Polly.Accounts do
  @moduledoc """
  Provides administrator authentication and account-management resources.

  The domain owns application users and the tokens used by authentication,
  confirmation, and password-reset flows.
  """

  use Ash.Domain,
    otp_app: :polly

  resources do
    resource Polly.Accounts.Token
    resource Polly.Accounts.User
  end
end
