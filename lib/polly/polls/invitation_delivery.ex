defmodule Polly.Polls.InvitationDelivery do
  @moduledoc "Tracks durable email invitation attempts without persisting voting URLs."

  use Ash.Resource,
    otp_app: :polly,
    domain: Polly.Polls,
    data_layer: AshSqlite.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  sqlite do
    table "poll_invitation_deliveries"
    repo Polly.Repo
  end

  field_policies do
    private_fields :include

    field_policy [:recipient_email, :provider_message_id] do
      authorize_if {Polly.Accounts.Checks.HasPermission, permission: :send_invitations}
    end

    field_policy :* do
      authorize_if always()
    end
  end

  actions do
    defaults [:read]

    create :queue do
      primary? true

      accept [
        :poll_id,
        :member_id,
        :access_grant_id,
        :requested_by_id,
        :operation_id,
        :kind,
        :dedupe_key,
        :recipient_email,
        :credential_version
      ]

      change set_attribute(:status, :queued)
      change set_attribute(:requested_at, &DateTime.utc_now/0)
    end

    update :record_attempt do
      accept [:status, :attempt_count, :last_error_code]
    end

    update :accept do
      accept [:provider_message_id, :attempt_count]
      change set_attribute(:status, :accepted)
      change set_attribute(:last_error_code, nil)
      change set_attribute(:accepted_at, &DateTime.utc_now/0)
    end

    update :fail do
      accept [:attempt_count, :last_error_code]
      change set_attribute(:status, :failed)
      change set_attribute(:failed_at, &DateTime.utc_now/0)
    end

    update :cancel do
      accept [:last_error_code]
      change set_attribute(:status, :cancelled)
      change set_attribute(:cancelled_at, &DateTime.utc_now/0)
    end
  end

  policies do
    policy action(:read) do
      authorize_if {Polly.Accounts.Checks.HasPermission,
                    permissions: [:send_invitations, :view_results, :view_jobs]}
    end

    policy action(:queue) do
      authorize_if {Polly.Accounts.Checks.HasPermission, permission: :send_invitations}
    end
  end

  attributes do
    uuid_primary_key :id
    attribute :operation_id, :uuid, allow_nil?: false, public?: true

    attribute :kind, :atom do
      allow_nil? false
      public? true
      constraints one_of: [:initial, :resend]
    end

    attribute :dedupe_key, :string, allow_nil?: false, public?: true

    attribute :status, :atom do
      allow_nil? false
      public? true
      default :queued
      constraints one_of: [:queued, :sending, :accepted, :failed, :cancelled]
    end

    attribute :recipient_email, :string do
      allow_nil? false
      sensitive? true
      constraints max_length: 320
    end

    attribute :requested_by_id, :uuid, allow_nil?: false, public?: true
    attribute :credential_version, :integer, allow_nil?: false, public?: true
    attribute :attempt_count, :integer, allow_nil?: false, public?: true, default: 0
    attribute :provider_message_id, :string, sensitive?: true
    attribute :last_error_code, :string, public?: true
    attribute :requested_at, :utc_datetime_usec, allow_nil?: false, public?: true
    attribute :accepted_at, :utc_datetime_usec, public?: true
    attribute :failed_at, :utc_datetime_usec, public?: true
    attribute :cancelled_at, :utc_datetime_usec, public?: true
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

    belongs_to :access_grant, Polly.Polls.AccessGrant do
      allow_nil? false
      public? true
    end
  end

  identities do
    identity :unique_dedupe_key, [:dedupe_key]
  end
end
