defmodule Polly.Polls.LifecycleTransition do
  @moduledoc """
  Persists a scheduled poll lifecycle transition.

  Phase 0 uses this resource to verify that an AshOban-generated worker can
  complete a scheduled record without changing a poll. Later phases add the
  production lifecycle kinds, relationships, authorization, and outcomes.
  """

  use Ash.Resource,
    otp_app: :polly,
    domain: Polly.Polls,
    data_layer: AshSqlite.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshOban]

  sqlite do
    table "poll_lifecycle_transitions"
    repo Polly.Repo
  end

  oban do
    triggers do
      trigger :execute_due_transition do
        action :complete_proof_of_concept
        where expr(state == :pending)
        worker_read_action(:read)
        scheduler_cron(false)
        queue(:poll_lifecycle)
        max_attempts(1)
        trigger_once?(true)
        actor_persister(:none)
        worker_module_name(Polly.Polls.LifecycleTransitionWorker)
      end
    end
  end

  actions do
    defaults [:read]

    create :create_proof_of_concept do
      accept [:scheduled_at]
    end

    update :complete_proof_of_concept do
      accept []
      require_atomic? false
      validate attribute_equals(:state, :pending)
      change set_attribute(:state, :completed)
      change set_attribute(:completed_at, &DateTime.utc_now/0)
    end
  end

  policies do
    bypass AshOban.Checks.AshObanInteraction do
      authorize_if always()
    end

    policy action_type(:read) do
      authorize_if {Polly.Accounts.Checks.HasPermission,
                    permissions: [:manage_polls, :publish_results]}
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :scheduled_at, :utc_datetime_usec do
      allow_nil? false
      public? true
    end

    attribute :state, Polly.Polls.LifecycleTransition.State do
      allow_nil? false
      public? true
      default :pending
    end

    attribute :completed_at, :utc_datetime_usec, public?: true

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end
end
