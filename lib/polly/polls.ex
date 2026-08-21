defmodule Polly.Polls do
  use Ash.Domain,
    otp_app: :polly

  resources do
    resource Polly.Polls.Option
    resource Polly.Polls.Poll
  end
end
