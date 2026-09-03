defmodule Polly.Polls.Ballot do
  @moduledoc """
  Records the final choices submitted for a poll.

  Ballots are created only by `Polly.Polls.Ballots.submit/3`; their database
  privacy mode is snapshotted at submission time. Identified ballots retain a
  member relationship, while anonymous ballots must not contain member
  identity. Each ballot may own one or more distinct selections.
  """

  use Ash.Resource,
    otp_app: :polly,
    domain: Polly.Polls,
    data_layer: AshSqlite.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  sqlite do
    table "poll_ballots"
    repo Polly.Repo
  end

  actions do
    defaults [:read]

    create :submit do
      accept [:poll_id, :member_id, :privacy_mode]
      change set_attribute(:submitted_at, &DateTime.utc_now/0)
      validate Polly.Polls.Validations.BallotPrivacyIsValid
    end
  end

  policies do
    bypass action(:submit) do
      authorize_if always()
    end

    policy action(:read) do
      authorize_if {Polly.Accounts.Checks.HasPermission, permission: :view_results}
    end
  end

  attributes do
    uuid_primary_key :id
    attribute :submitted_at, :utc_datetime_usec, allow_nil?: false, public?: true

    attribute :privacy_mode, Polly.Polls.Poll.PrivacyMode do
      allow_nil? false
      default :identified
      public? true
    end

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :poll, Polly.Polls.Poll do
      allow_nil? false
      public? true
    end

    belongs_to :member, Polly.Members.Member do
      allow_nil? true
      public? true
    end

    has_many :selections, Polly.Polls.Selection do
      destination_attribute :ballot_id
    end
  end

  identities do
    identity :unique_poll_member, [:poll_id, :member_id]
  end
end
