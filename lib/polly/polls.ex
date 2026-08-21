defmodule Polly.Polls do
  @moduledoc """
  Provides poll configuration, lifecycle, electorate, and access management.

  The domain owns polls and their options, eligibility snapshots, and revocable
  member access grants.
  """

  use Ash.Domain,
    otp_app: :polly

  resources do
    resource Polly.Polls.AccessGrant
    resource Polly.Polls.Eligibility
    resource Polly.Polls.Option
    resource Polly.Polls.Poll
  end
end
