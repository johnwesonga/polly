defmodule Polly.Polls.LifecycleTransition do
  @moduledoc """
  Persists a scheduled poll lifecycle transition.

  It records who configured an opening or closing transition, when it should
  run, and its eventual outcome. The generated AshOban worker remains a
  harmless state-transition proof of concept until Phase 2 connects it to the
  poll lifecycle.
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

    custom_indexes do
      index [:state, :scheduled_at],
        name: "poll_lifecycle_transitions_due_index"

      index [:poll_id, :kind, :state],
        name: "poll_lifecycle_transitions_poll_kind_state_index"

      index [:poll_id, :kind],
        name: "poll_lifecycle_transitions_one_pending_kind_index",
        unique: true,
        where: "state = 'pending'",
        message: "already has a pending transition of this kind"
    end
  end

  oban do
    triggers do
      trigger :execute_due_transition do
        action :execute
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

    create :schedule do
      public? false
      accept [:poll_id, :kind, :scheduled_at, :scheduled_by_id, :replaces_transition_id]
    end

    update :execute do
      public? false
      accept []
      require_atomic? false
      validate attribute_equals(:state, :pending)
      change set_attribute(:state, :completed)
      change set_attribute(:completed_at, &DateTime.utc_now/0)
    end

    update :cancel do
      public? false
      accept []
      require_atomic? false
      validate attribute_equals(:state, :pending)
      change set_attribute(:state, :cancelled)
      change set_attribute(:cancelled_at, &DateTime.utc_now/0)
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

    attribute :kind, Polly.Polls.LifecycleTransition.Kind do
      allow_nil? false
      public? true
    end

    attribute :state, Polly.Polls.LifecycleTransition.State do
      allow_nil? false
      public? true
      default :pending
    end

    attribute :completed_at, :utc_datetime_usec, public?: true
    attribute :cancelled_at, :utc_datetime_usec, public?: true
    attribute :failure_code, :string, public?: true

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :poll, Polly.Polls.Poll do
      allow_nil? false
      public? true
    end

    belongs_to :scheduled_by, Polly.Accounts.User do
      allow_nil? false
      public? true
    end

    belongs_to :replaces_transition, __MODULE__ do
      public? true
    end
  end
end
