defmodule Polly.Members do
  @moduledoc """
  Provides the reusable member roster used to configure poll electorates.

  Member records are managed independently from polls so historical poll
  participation can be retained through eligibility snapshots.
  """

  use Ash.Domain,
    otp_app: :polly

  resources do
    resource Polly.Members.Member
  end
end
