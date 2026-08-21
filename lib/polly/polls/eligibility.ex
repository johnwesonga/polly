defmodule Polly.Polls.Eligibility do
  use Ash.Resource,
    otp_app: :polly,
    domain: Polly.Polls,
    data_layer: AshSqlite.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  sqlite do
    table "poll_eligibilities"
    repo Polly.Repo
  end

  actions do
    defaults [:read]

    create :create do
      primary? true
      accept [:poll_id, :member_id]
      validate Polly.Polls.Validations.PollIsDraft
    end

    destroy :destroy do
      primary? true
      require_atomic? false
      validate Polly.Polls.Validations.PollIsDraft
    end
  end

  policies do
    policy always() do
      authorize_if actor_present()
    end
  end

  attributes do
    uuid_primary_key :id
    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :poll, Polly.Polls.Poll do
      allow_nil? false
      public? true
    end

    belongs_to :member, Polly.Members.Member do
      allow_nil? false
      public? true
    end
  end

  identities do
    identity :unique_poll_member, [:poll_id, :member_id]
  end
end
