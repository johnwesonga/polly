defmodule Polly.Members.Member do
  @moduledoc """
  Represents a roster member who may be selected for a poll's electorate.

  Members are reusable across polls and can be made inactive without changing
  historical eligibility snapshots.
  """

  use Ash.Resource,
    otp_app: :polly,
    domain: Polly.Members,
    data_layer: AshSqlite.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  sqlite do
    table "members"
    repo Polly.Repo
  end

  actions do
    read :read do
      primary? true

      pagination do
        keyset? true
        required? false
        default_limit 15
      end
    end

    create :create do
      primary? true
      accept [:name, :email]
      change Polly.Members.Changes.NormalizeEmail
      change {Polly.Audit.Changes.AppendMemberEvent, action: "member.created"}
    end

    update :update do
      primary? true
      accept [:name, :email, :active]
      require_atomic? false
      change Polly.Members.Changes.NormalizeEmail
      change {Polly.Audit.Changes.AppendMemberEvent, action: "member.updated"}
    end
  end

  policies do
    policy action(:read) do
      authorize_if {Polly.Accounts.Checks.HasPermission, permission: :manage_members}
    end

    policy action([:create, :update]) do
      authorize_if {Polly.Accounts.Checks.HasPermission, permission: :manage_members}
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :name, :string do
      allow_nil? false
      public? true
      constraints min_length: 1, max_length: 160, trim?: true
    end

    attribute :email, :string do
      public? true
      constraints max_length: 320, trim?: true, match: ~r/^[^\s]+@[^\s]+\.[^\s]+$/
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
    has_many :ballots, Polly.Polls.Ballot do
      destination_attribute :member_id
    end

    has_many :invitation_deliveries, Polly.Polls.InvitationDelivery do
      destination_attribute :member_id
    end
  end

  identities do
    identity :unique_email, [:email]
  end
end
