defmodule Polly.Polls.Poll do
  @moduledoc """
  Represents a configurable poll and controls its forward-only lifecycle.

  A poll owns its ballot options, electorate, access grants, and result
  publication state.
  """

  use Ash.Resource,
    otp_app: :polly,
    domain: Polly.Polls,
    data_layer: AshSqlite.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  sqlite do
    table "polls"
    repo Polly.Repo
  end

  actions do
    defaults [:read]

    create :create_draft do
      primary? true
      accept [:title, :description, :slug]
    end

    update :update_draft do
      accept [:title, :description]
      validate attribute_equals(:status, :draft), message: "can only be edited while in draft"
    end

    update :open do
      accept []
      require_atomic? false
      validate attribute_equals(:status, :draft), message: "must be a draft to open"
      validate Polly.Polls.Validations.HasMinimumOptions
      validate Polly.Polls.Validations.HasEligibleMembers
      change set_attribute(:status, :open)
      change set_attribute(:opened_at, &DateTime.utc_now/0)
    end

    update :close do
      accept []
      validate attribute_equals(:status, :open), message: "must be open to close"
      change set_attribute(:status, :closed)
      change set_attribute(:closed_at, &DateTime.utc_now/0)
    end
  end

  policies do
    policy always() do
      authorize_if actor_present()
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :title, :string do
      allow_nil? false
      public? true
      constraints min_length: 1, max_length: 160, trim?: true
    end

    attribute :description, :string do
      public? true
      constraints max_length: 2_000, trim?: true
    end

    attribute :slug, :string do
      allow_nil? false
      public? true
      constraints min_length: 1, max_length: 180, match: ~r/^[a-z0-9]+(?:-[a-z0-9]+)*$/
    end

    attribute :status, Polly.Polls.Poll.Status do
      allow_nil? false
      public? true
      default :draft
    end

    attribute :selection_mode, Polly.Polls.Poll.SelectionMode do
      allow_nil? false
      public? true
      default :single
    end

    attribute :opened_at, :utc_datetime_usec, public?: true
    attribute :closed_at, :utc_datetime_usec, public?: true
    attribute :results_published_at, :utc_datetime_usec, public?: true

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    has_many :eligibilities, Polly.Polls.Eligibility do
      destination_attribute :poll_id
    end

    has_many :access_grants, Polly.Polls.AccessGrant do
      destination_attribute :poll_id
    end

    has_many :options, Polly.Polls.Option do
      destination_attribute :poll_id
      sort position: :asc
    end
  end

  identities do
    identity :unique_slug, [:slug]
  end
end
