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
      change {Polly.Audit.Changes.AppendOptionEvent, action: "poll_option.created"}
    end

    update :update do
      primary? true
      accept [:label, :position, :active]
      require_atomic? false
      validate Polly.Polls.Validations.PollIsDraft
      change {Polly.Audit.Changes.AppendOptionEvent, action: "poll_option.updated"}
    end

    destroy :destroy do
      primary? true
      require_atomic? false
      validate Polly.Polls.Validations.PollIsDraft
      change {Polly.Audit.Changes.AppendOptionEvent, action: "poll_option.deleted"}
    end
  end

  policies do
    policy action(:read) do
      authorize_if {Polly.Accounts.Checks.HasPermission,
                    permissions: [:manage_polls, :view_results]}
    end

    policy action([:create, :update, :destroy]) do
      authorize_if {Polly.Accounts.Checks.HasPermission, permission: :manage_polls}
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

    has_many :selections, Polly.Polls.Selection do
      destination_attribute :option_id
    end
  end

  identities do
    identity :unique_position, [:poll_id, :position]
  end
end
