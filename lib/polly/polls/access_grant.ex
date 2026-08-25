defmodule Polly.Polls.AccessGrant do
  @moduledoc """
  Stores a revocable credential granting one eligible member access to one poll.

  Tokens are poll-scoped and may be revoked, reissued, or optionally expired.
  """

  use Ash.Resource,
    otp_app: :polly,
    domain: Polly.Polls,
    data_layer: AshSqlite.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  sqlite do
    table "poll_access_grants"
    repo Polly.Repo
  end

  code_interface do
    define :resolve, action: :resolve, args: [:poll_id, :token]
  end

  actions do
    defaults [:read]

    read :resolve do
      get? true
      argument :poll_id, :uuid, allow_nil?: false
      argument :token, :string, allow_nil?: false

      filter expr(
               poll_id == ^arg(:poll_id) and token == ^arg(:token) and is_nil(revoked_at) and
                 (is_nil(expires_at) or expires_at > now())
             )
    end

    create :issue do
      primary? true
      accept [:poll_id, :member_id, :expires_at]
      change set_attribute(:token, &__MODULE__.generate_token/0)
      validate Polly.Polls.Validations.MemberIsEligible
    end

    update :revoke do
      accept []
      change set_attribute(:revoked_at, &DateTime.utc_now/0)
    end
  end

  policies do
    bypass action(:resolve) do
      authorize_if always()
    end

    policy always() do
      authorize_if actor_present()
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :token, :string do
      allow_nil? false
      public? true
      sensitive? true
    end

    attribute :revoked_at, :utc_datetime_usec, public?: true
    attribute :expires_at, :utc_datetime_usec, public?: true
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

    has_many :invitation_deliveries, Polly.Polls.InvitationDelivery do
      destination_attribute :access_grant_id
    end
  end

  identities do
    identity :unique_token, [:token]
  end

  def generate_token do
    32
    |> :crypto.strong_rand_bytes()
    |> Base.url_encode64(padding: false)
  end
end
