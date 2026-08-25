defmodule Polly.Audit.Event do
  @moduledoc "An append-only snapshot of a committed administrator action."

  use Ash.Resource,
    otp_app: :polly,
    domain: Polly.Audit,
    data_layer: AshSqlite.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  sqlite do
    table "audit_events"
    repo Polly.Repo
  end

  actions do
    defaults [:read]

    create :append do
      public? false

      accept [
        :operation_id,
        :action,
        :actor_id,
        :actor_label,
        :target_type,
        :target_id,
        :target_label,
        :poll_id,
        :metadata,
        :source,
        :request_id,
        :occurred_at
      ]
    end
  end

  policies do
    policy always() do
      authorize_if actor_present()
    end
  end

  attributes do
    uuid_primary_key :id
    attribute :operation_id, :uuid, allow_nil?: false, public?: true
    attribute :action, :string, allow_nil?: false, public?: true
    attribute :actor_id, :uuid, allow_nil?: false, public?: true
    attribute :actor_label, :string, allow_nil?: false, public?: true
    attribute :target_type, :string, allow_nil?: false, public?: true
    attribute :target_id, :uuid, public?: true
    attribute :target_label, :string, allow_nil?: false, public?: true
    attribute :poll_id, :uuid, public?: true
    attribute :metadata, :map, allow_nil?: false, public?: true, default: %{}
    attribute :source, :string, allow_nil?: false, public?: true, default: "admin_ui"
    attribute :request_id, :string, public?: true
    attribute :occurred_at, :utc_datetime_usec, allow_nil?: false, public?: true
    create_timestamp :inserted_at
  end

  identities do
    identity :unique_operation, [:operation_id]
  end
end
