defmodule Polly.Polls.Option do
  @moduledoc """
  Represents an administrator-defined choice displayed on a poll's ballot.

  Options belong to one poll, have deterministic ordering, and are frozen when
  the poll leaves the draft state.
  """

  use Ash.Resource,
    otp_app: :polly,
    domain: Polly.Polls,
    data_layer: AshSqlite.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  sqlite do
    table "poll_options"
    repo Polly.Repo
  end

  actions do
    defaults [:read]

    create :create do
      primary? true
      accept [:poll_id, :label, :position]
      validate Polly.Polls.Validations.PollIsDraft
    end

    update :update do
      primary? true
      accept [:label, :position, :active]
      require_atomic? false
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

    attribute :label, :string do
      allow_nil? false
      public? true
      constraints min_length: 1, max_length: 160, trim?: true
    end

    attribute :position, :integer do
      allow_nil? false
      public? true
      constraints min: 1
    end

    attribute :active, :boolean do
      allow_nil? false
      public? true
      default true
    end

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :poll, Polly.Polls.Poll do
      allow_nil? false
      public? true
    end
  end

  identities do
    identity :unique_position, [:poll_id, :position]
  end
end
