defmodule Polly.Polls do
  @moduledoc """
  Provides poll configuration, lifecycle, electorate, access, and voting.

  The domain owns polls and their options, eligibility snapshots, and revocable
  member access grants.
  """

  use Ash.Domain,
    otp_app: :polly

  resources do
    resource Polly.Polls.AccessGrant
    resource Polly.Polls.Ballot
    resource Polly.Polls.Eligibility
    resource Polly.Polls.InvitationDelivery
    resource Polly.Polls.Option
    resource Polly.Polls.Participation
    resource Polly.Polls.Poll
    resource Polly.Polls.Selection
  end
end
