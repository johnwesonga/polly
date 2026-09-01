defmodule Polly.Polls.AccessGrant do
  @moduledoc """
  Stores a revocable credential granting one eligible member access to one poll.

  New grants persist only a derived-token digest and derivation inputs. The
  nullable plaintext token remains temporarily for legacy grants created before
  credential protection was introduced.
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

  actions do
    defaults [:read]

    read :resolve do
      get? true
      argument :poll_id, :uuid, allow_nil?: false
      argument :token, :string, allow_nil?: false
      argument :token_digest, :string, allow_nil?: false

      filter expr(
               poll_id == ^arg(:poll_id) and
                 (token_digest == ^arg(:token_digest) or
                    (is_nil(token_digest) and token == ^arg(:token))) and is_nil(revoked_at) and
                 (is_nil(expires_at) or expires_at > now())
             )
    end

    create :issue do
      primary? true
      accept [:poll_id, :member_id, :expires_at]
      change Polly.Polls.Changes.SetDerivedVoterCredential
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

    policy action([:read, :issue, :revoke]) do
      authorize_if {Polly.Accounts.Checks.HasPermission, permission: :manage_access_grants}
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :token, :string do
      allow_nil? true
      sensitive? true
    end

    attribute :token_digest, :string, sensitive?: true
    attribute :credential_nonce, :string, sensitive?: true

    attribute :credential_version, :integer do
      allow_nil? false
      default 0
      constraints min: 0
    end

    attribute :credential_issued_at, :utc_datetime_usec

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
    identity :unique_token_digest, [:token_digest]
  end

  @doc "Resolves an active poll-scoped grant from a supplied voting credential."
  def resolve(poll_id, token) when is_binary(token) do
    result =
      __MODULE__
      |> Ash.Query.for_read(:resolve, %{
        poll_id: poll_id,
        token: token,
        token_digest: Polly.Polls.VoterCredential.digest(token)
      })
      |> Ash.read_one(authorize?: false)

    case result do
      {:ok, nil} -> {:error, %Ash.Error.Invalid{}}
      other -> other
    end
  end

  @doc false
  def derive_token_for_delivery(%{token: token}) when is_binary(token), do: token

  def derive_token_for_delivery(grant) do
    Polly.Polls.VoterCredential.derive(
      grant.id,
      grant.credential_nonce,
      grant.credential_version
    )
  end
end
