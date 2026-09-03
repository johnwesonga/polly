defmodule Polly.Polls.Participation do
  @moduledoc """
  Records that an eligible member completed a final submission for a poll.

  Participation is intentionally separate from ballots and selections. It may
  identify the member and submission time, but must never contain a ballot,
  option, selection, access-grant, invitation, or shared operation reference.
  """

  use Ash.Resource,
    otp_app: :polly,
    domain: Polly.Polls,
    data_layer: AshSqlite.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  require Ash.Query

  sqlite do
    table "poll_participations"
    repo Polly.Repo
  end

  actions do
    defaults [:read]

    create :record do
      accept [:poll_id, :member_id]
      change set_attribute(:participated_at, &DateTime.utc_now/0)
    end
  end

  policies do
    policy action(:read) do
      authorize_if {Polly.Accounts.Checks.HasPermission, permission: :view_results}
    end
  end

  attributes do
    uuid_primary_key :id
    attribute :participated_at, :utc_datetime_usec, allow_nil?: false, public?: true
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
  end

  identities do
    identity :unique_poll_member, [:poll_id, :member_id]
  end

  @doc "Returns whether one member has completed a submission for the poll."
  @spec submitted?(Ecto.UUID.t(), Ecto.UUID.t()) :: boolean()
  def submitted?(poll_id, member_id) do
    __MODULE__
    |> Ash.Query.filter(poll_id == ^poll_id and member_id == ^member_id)
    |> Ash.exists?(authorize?: false)
  end

  @doc "Returns the IDs of members who completed submissions for the poll."
  @spec submitted_member_ids(Ecto.UUID.t(), term()) :: MapSet.t(Ecto.UUID.t())
  def submitted_member_ids(poll_id, actor) do
    __MODULE__
    |> Ash.Query.filter(poll_id == ^poll_id)
    |> Ash.Query.select([:member_id])
    |> Ash.read!(actor: actor)
    |> MapSet.new(& &1.member_id)
  end
end
