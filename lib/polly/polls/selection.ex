defmodule Polly.Polls.Selection do
  @moduledoc "Stores an immutable option choice belonging to a submitted ballot."

  use Ash.Resource,
    otp_app: :polly,
    domain: Polly.Polls,
    data_layer: AshSqlite.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  sqlite do
    table "poll_selections"
    repo Polly.Repo
  end

  actions do
    defaults [:read]

    create :select do
      accept [:ballot_id, :option_id]
    end
  end

  policies do
    policy always() do
      authorize_if actor_present()
    end
  end

  attributes do
    uuid_primary_key :id
    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :ballot, Polly.Polls.Ballot do
      allow_nil? false
      public? true
    end

    belongs_to :option, Polly.Polls.Option do
      allow_nil? false
      public? true
    end
  end

  identities do
    identity :one_selection_per_ballot, [:ballot_id]
  end
end
