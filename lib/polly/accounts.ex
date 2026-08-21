defmodule Polly.Accounts do
  use Ash.Domain,
    otp_app: :polly

  resources do
    resource Polly.Accounts.Token
    resource Polly.Accounts.User
  end
end
