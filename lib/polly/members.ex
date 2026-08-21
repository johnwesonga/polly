defmodule Polly.Members do
  use Ash.Domain,
    otp_app: :polly

  resources do
    resource Polly.Members.Member
  end
end
