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
    defaults [:read]

    create :create do
      primary? true
      accept [:name, :email]
    end

    update :update do
      primary? true
      accept [:name, :email, :active]
    end
  end

  policies do
    policy always() do
      authorize_if actor_present()
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
end
