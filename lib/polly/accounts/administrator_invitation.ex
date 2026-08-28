defmodule Polly.Accounts.AdministratorInvitation do
  @moduledoc "A time-limited invitation to create a Polly administrator account."

  use Ash.Resource,
    otp_app: :polly,
    domain: Polly.Accounts,
    data_layer: AshSqlite.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  sqlite do
    table "administrator_invitations"
    repo Polly.Repo
  end

  actions do
    defaults [:read]

    create :invite do
      accept [:email, :role, :invited_by_id, :expires_at]
    end

    update :record_delivery do
      accept [:delivery_status, :sent_at, :send_count, :last_error_code]
    end

    update :revoke do
      accept [:revoked_at]
      change set_attribute(:status, :revoked)
    end

    update :expire do
      accept []
      change set_attribute(:status, :expired)
    end

    update :accept do
      accept [:accepted_user_id, :accepted_at]
      change set_attribute(:status, :accepted)
    end
  end

  policies do
    policy action(:read) do
      authorize_if {Polly.Accounts.Checks.HasPermission, permission: :manage_administrators}
    end
  end

  attributes do
    uuid_primary_key :id
    attribute :email, :ci_string, allow_nil?: false, public?: true
    attribute :role, Polly.Accounts.User.Role, allow_nil?: false, public?: true

    attribute :status, Polly.Accounts.AdministratorInvitation.Status,
      allow_nil?: false,
      public?: true,
      default: :pending

    attribute :invited_by_id, :uuid, allow_nil?: false, public?: true
    attribute :accepted_user_id, :uuid, public?: true
    attribute :expires_at, :utc_datetime_usec, allow_nil?: false, public?: true
    attribute :sent_at, :utc_datetime_usec, public?: true
    attribute :send_count, :integer, allow_nil?: false, public?: true, default: 0

    attribute :delivery_status, :atom,
      allow_nil?: false,
      public?: true,
      default: :queued,
      constraints: [one_of: [:queued, :sending, :sent, :failed]]

    attribute :last_error_code, :string, public?: true
    attribute :revoked_at, :utc_datetime_usec, public?: true
    attribute :accepted_at, :utc_datetime_usec, public?: true
    timestamps()
  end
end
