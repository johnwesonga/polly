# Scheduled Poll Opening and Closing — Technical Specification

## Status

Phases 0 and 1 implemented. Production poll lifecycle execution begins in
Phase 2.

This feature is Polly's proposed greenfield evaluation of AshOban. It begins
with a contained proof of concept before touching the production poll
lifecycle.

## Summary

Allow administrators to schedule future poll opening and closing. Each request
is persisted as an Ash resource and immediately handed to an AshOban-generated
worker with its requested execution time. The worker later reloads the record
and invokes an Ash action that applies the existing poll lifecycle rules.

This is intentionally an **AshOban implementation**, not a handwritten
`Oban.Worker` implementation. Polly still owns its lifecycle rules, audit
events, safe failure states, and PubSub broadcasts. AshOban owns job discovery,
worker generation, record loading, locking, retries, and final-error dispatch.

Scheduling does not add poll statuses. A scheduled draft stays `:draft` until
opening succeeds; an open poll stays `:open` until closing succeeds. Schedule
state is shown separately. The first iteration accepts and displays explicitly
labelled UTC date-times.

## Why use a greenfield feature

Polly's invitation workers are working, tested security boundaries.
Retrofitting AshOban would relocate their email, credential, provider
idempotency, and delivery-state logic without eliminating it.

Scheduled lifecycle transitions naturally fit AshOban's resource-driven model:

```text
persist pending transition
→ schedule its generated AshOban worker for the requested time
→ transition becomes due
→ generated worker invokes an Ash action
→ action updates poll and transition
→ record no longer matches the trigger
```

If the implementation works well with AshSQLite, `Oban.Engines.Lite`, audit
attribution, deployment, and tests, it can guide later scheduled reminders,
expiry processing, and maintenance jobs.

## Complexity and risks

This is a **medium-complexity** feature. AshOban removes infrastructure code,
not lifecycle complexity. Principal risks are:

- cancelled or replaced work executing from an older queued job;
- opening failing readiness checks;
- manual and scheduled transitions racing;
- duplicate execution after retry or deployment;
- time-based trigger queries changing while records are streamed;
- incorrect actor or audit attribution;
- unsupported locking behavior with AshSQLite; and
- every Fly.io Machine sleeping when work becomes due.

Use one record per transition, state-based idempotency, execution-time
validation, explicit generated module names, bounded retries, UTC timing, and a
production availability gate.

## Goals

- Schedule a draft poll to open.
- Schedule a draft or open poll to close.
- Configure an opening and closing window together.
- Survive restarts and deployments.
- Use AshOban without a feature-specific handwritten worker.
- Reuse `Poll.open` and `Poll.close` actions and validations.
- Show pending, completed, cancelled, skipped, and failed transitions.
- Allow authorized replacement and cancellation.
- Make retries and repeat execution idempotent.
- Audit configuration separately from automatic execution.
- Keep voter, credential, ballot, and choice data out of jobs and diagnostics.

## Non-goals

- Rewriting either invitation worker.
- Automatically publishing results or sending invitations/reminders.
- Recurring polls or lifecycle transitions.
- Reopening a closed poll or moving an open poll back to draft.
- Scheduling configuration or result-visibility changes.
- Per-administrator time zones in the first iteration.
- Second-level execution guarantees.
- Waking a stopped Fly application without external infrastructure.

## AshOban versus handwritten Oban

### Selected: AshOban trigger

AshOban owns:

- querying due records;
- generated scheduler and worker modules;
- one job per matching record;
- primary-key reload and resource locking;
- queue, attempts, priority, timeout, and backoff;
- invoking `:execute`; and
- invoking an `on_error` action after final failure.

Polly owns:

- schedule creation, replacement, and cancellation;
- readiness and lifecycle rules;
- calling `Poll.open` or `Poll.close`;
- outcome and error classification;
- audit attribution, telemetry, and PubSub; and
- administrator, deployment, and privacy behavior.

“Pure AshOban” means no manual lifecycle worker or `Oban.insert` call. It does
not mean custom business logic disappears.

### Rejected by default: handwritten worker

The alternative is a custom `Polly.Polls.LifecycleWorker` whose job contains a
transition ID. The scheduling service would insert jobs and implement
uniqueness, loading, attempt handling, final failure, and stale-work rejection.
This offers maximum control but duplicates the infrastructure being evaluated.

Use it only if Phase 0 proves a material AshOban problem: unsupported SQLite
locking, unsafe arguments, unreliable transaction behavior, insufficient retry
control, or tests that are materially harder to understand.

| Concern | AshOban | Handwritten Oban |
| --- | --- | --- |
| Worker/scheduler | Generated from resource DSL | Manually maintained |
| Due-record discovery | Trigger query | Custom scheduler or scheduled jobs |
| Execution | Native Ash action | Worker calls service/action |
| Locking | AshOban orchestration | Explicit application code |
| Retry/final error | DSL and `on_error` | Worker callbacks/attempt checks |
| Cancellation safety | Record state revalidation | Explicit state/version checks |
| Domain/audit/PubSub | Custom Ash logic | Custom domain logic |

## Lifecycle and product rules

The lifecycle remains:

```text
draft ── open ── closed
```

1. Only a draft poll may receive an opening transition.
2. A draft or open poll may receive a closing transition.
3. A closed poll cannot be scheduled.
4. New times must be future UTC values; closing must follow opening.
5. Opening executes all normal readiness checks at execution time.
6. Scheduling an unready draft is allowed with a visible warning.
7. A readiness failure leaves the poll draft and marks the transition failed.
8. A later close records a skip if the poll never opened.
9. Manual opening makes pending opening inapplicable but preserves closing.
10. Manual closing makes every pending lifecycle transition inapplicable.
11. Editing cancels the old record and creates a replacement.
12. Non-pending transitions can never mutate a poll.
13. Closing never publishes results.

## Time semantics

Show UTC explicitly, including in confirmation:

```text
Opens: 2026-09-12 17:00 UTC
Closes: 2026-09-19 17:00 UTC
```

Persist `:utc_datetime_usec`. Use a configurable one-minute lead time and
one-year horizon. Execution remains best effort; copy says “scheduled for,” not
“will open exactly at.” Record both requested and actual times.

An overdue transition runs after the application resumes. Future time-zone
support must use a maintained time-zone database and define daylight-saving
ambiguities.

## Data model

Add `Polly.Polls.LifecycleTransition`, backed by
`poll_lifecycle_transitions`. One record represents one open or close request.

| Attribute | Type | Purpose |
| --- | --- | --- |
| `id` | UUID | Primary key and generated-job identifier. |
| `poll_id` | UUID | Poll relationship. |
| `kind` | enum | `:open` or `:close`. |
| `scheduled_at` | UTC datetime | Requested time. |
| `state` | enum | `:pending`, `:completed`, `:cancelled`, `:failed`, `:skipped`. |
| `scheduled_by_id` | UUID | Configuring administrator. |
| `completed_at` | UTC datetime | Actual completion, when successful. |
| `cancelled_at` | UTC datetime | Cancellation time. |
| `failure_code` | string | Safe allow-listed failure or skip code. |
| `replaces_transition_id` | UUID | Superseded transition, when applicable. |
| timestamps | UTC datetime | Standard timestamps. |

Index `(state, scheduled_at)` and `(poll_id, kind, state)`. Enforce at most one
pending transition of each kind per poll, preferably with a partial unique
index. Retain historical rows.

Safe codes include `poll_not_draft`, `poll_not_open`,
`selection_rules_invalid`, `insufficient_options`,
`selection_limits_invalid`, `no_eligible_members`, and `transition_failed`.
No member, grant, delivery, ballot, participation, selection, token, or URL
fields belong in this resource.

## Resource and domain actions

Suggested resource actions are `:schedule`, `:execute`, `:cancel`, and
`:execution_failed`. The execute action accepts no browser-controlled fields,
requires pending state, and delegates to
`Polly.Polls.Changes.ExecuteLifecycleTransition`. The final-error action accepts
AshOban's error argument but stores only an allow-listed code.

Administrator commands use a service boundary:

```elixir
Polly.Polls.LifecycleScheduling.schedule(poll, attributes, actor)
Polly.Polls.LifecycleScheduling.cancel(transition, actor)
Polly.Polls.LifecycleScheduling.replace(transition, scheduled_at, actor)
Polly.Polls.LifecycleScheduling.list_for_poll(poll, actor)
```

The service authorizes, normalizes UTC input, validates poll state and ordering,
cancels superseded rows, creates replacements, and appends audit events. It
does not construct workers or insert Oban jobs.

The execution action reloads the poll and calls the existing `Poll.open` or
`Poll.close` action. Readiness rules must not be copied into the trigger filter:
the filter decides what is due; the action decides what is valid.

## AshOban trigger

The target design is conceptually:

```elixir
oban do
  triggers do
    trigger :execute_due_transition do
      action :execute
      where expr(state == :pending and scheduled_at <= now())
      read_action :read
      worker_read_action :read_pending
      scheduler_cron false
      queue :poll_lifecycle
      max_attempts 5
      on_error :execution_failed
      shared_context [:job]

      worker_module_name Polly.Polls.LifecycleTransitionWorker
      scheduler_module_name Polly.Polls.LifecycleTransitionScheduler
    end
  end
end
```

Verify exact DSL against the installed version during Phase 0. Important
choices:

- Set stable worker/scheduler module names so refactors do not strand jobs.
- Set `scheduler_cron false`; AshOban 0.8 otherwise defaults to every minute.
- Schedule the generated worker directly at `scheduled_at` when the transition
  is created or replaced.
- Use a dedicated `poll_lifecycle: 1` queue.
- Keep successful/cancelled/skipped/failed rows outside pending state.
- Use job context only for bounded attempt/timing information.
- Inspect persisted arguments for sensitive or unexpectedly broad actor data.

Outcomes are completed, cancelled, skipped, deterministic failure, transient
retry, or already handled. `on_error` should do only the minimum safe terminal
state update because failure handling can itself fail.

## Concurrency and idempotency

Generated workers reload the transition and require pending state. Existing
Poll actions retain status validation. Cancellation and replacement move old
rows out of the trigger condition. If a manual action commits first, generated
execution records a skip; if generated execution commits first, the manual
action receives the existing validation error.

AshOban normally locks triggered records in a transaction. Phase 0 must verify
its `lock_for_update?` behavior with AshSQLite. SQLite serialization helps but
must not be the sole correctness mechanism.

## Authorization and actor handling

Opening schedules require `:manage_polls`; closing schedules require
`:publish_results`; configuring both requires both. Execution is trusted
fulfillment of a previously authorized command and does not depend on an active
browser session.

Phase 0 must compare:

1. an `AshOban.PersistActor` that restores the configuring administrator; and
2. a restricted system actor with `scheduled_by_id` retained for attribution.

Prefer the system actor if persisting an administrator would place unnecessary
attributes in job arguments. Disabling the configuring administrator later
does not silently cancel an authorized schedule. Document generated-worker and
trusted calls in `Polly.Accounts.AuthorizationCoverage`.

## Audit and observability

Add `poll.lifecycle_scheduled`, `poll.lifecycle_schedule_replaced`,
`poll.lifecycle_schedule_cancelled`, `poll.opened_automatically`,
`poll.closed_automatically`, and `poll.lifecycle_schedule_failed`.

Configuration uses administrator attribution and `admin_ui`; execution uses
`scheduled_job` and distinguishes executor from configurator. Safe metadata is
limited to transition kind, requested/actual UTC time, and failure code. Never
persist Oban arguments, raw errors, member data, credentials, or choices.

Measure scheduled counts, execution delay, outcome, retry, and bounded failure
codes. Failed transitions appear in dashboard Action Required, not only Oban
Web.

## Administrator experience

Introduce a poll **Overview** or **Lifecycle** section. Move manual Open and
Close controls out of Results so that Results focuses on turnout, aggregates,
publication, and export.

- Draft: readiness, UTC schedule form, pending transitions, and Open now.
- Open: actual opening/duration, close scheduling, and Close now.
- Closed: actual times and transition history; no new scheduling.

Confirm normalized UTC values. Replacing or cancelling an imminent transition
requires explicit confirmation. Show safe, actionable failures.

## Fly.io requirements

AshOban still requires running scheduler and worker processes. Jobs and
transition rows survive restart on the SQLite volume, but nothing executes
while every Machine is stopped or suspended. Production enablement therefore
requires `min_machines_running = 1` with compatible auto-stop settings, or a
documented external wake mechanism. The first release requires an always-on
Machine.

## Testing strategy

Phase 0 must prove:

- AshOban integrates without changing existing invitation workers;
- explicit generated module names and queue work;
- due records execute and future/non-pending records do not;
- persisted arguments contain no sensitive state;
- SQLite locking, retries, restart recovery, and Oban Web work; and
- completed records cannot execute twice.

Later suites cover time validation, role permissions, readiness failures,
open/close execution, manual races, cancellation/replacement, `on_error`, audit
attribution, PubSub, LiveView behavior, and leakage across jobs, logs, errors,
telemetry, audits, and HTML. Use `Oban.Testing` and explicit times, never sleeps.

## Implementation phases

### Phase 0 — AshOban proof of concept

- Add `ash_oban` and integrate `AshOban.config/2` with existing Oban config.
- Add a minimal transition state model.
- Generate a trigger that marks a due test record completed without touching a
  poll.
- Inspect worker arguments and actor strategies.
- Verify SQLite locking, retry, restart, tests, Oban Web, and coexistence.
- Record a go/no-go decision with evidence.

This PR stays small and does not call `Poll.open` or `Poll.close`.

#### Phase 0 findings

- AshOban 0.8.14 is integrated through `AshOban.config/2` alongside Polly's
  existing handwritten invitation workers.
- The trigger has `scheduler_cron false`; creating a production schedule will
  enqueue its generated worker directly for the transition's `scheduled_at`.
- The generated worker uses the stable module name
  `Polly.Polls.LifecycleTransitionWorker` and the dedicated
  `poll_lifecycle` queue.
- Worker arguments contain only the transition primary key and empty AshOban
  bookkeeping maps. No actor, poll, member, ballot, credential, or choice data
  is persisted in the proof-of-concept job.
- A pending record completes once; a stale job is cancelled after the record
  leaves the pending state.
- `Oban.Engines.Lite`, AshSQLite, manual Oban testing, and the existing Oban Web
  installation coexist successfully in the focused test suite.
- Phase 0 uses no persisted actor. Phase 1 will retain the configuring
  administrator on the transition record while automatic execution uses a
  restricted trusted boundary.

**Decision:** proceed to Phase 1. The proof of concept found no need for a
feature-specific handwritten worker. Transaction races and restart behavior
still require production-level tests once the poll relationship and scheduling
service exist.

### Phase 1 — Production resource and scheduling service

- Finalize enums, relationships, constraints, indexes, and migration.
- Add authorized schedule, replace, cancel, and listing boundaries.
- Add UTC and opening/closing-order validation.
- Add configuration audits and update the IEx how-to.

#### Phase 1 implementation notes

- `LifecycleTransition` now records its poll, `:open` or `:close` kind,
  configuring administrator, replacement lineage, outcome timestamps, and safe
  failure code.
- Partial and supporting SQLite indexes enforce one pending transition per poll
  and kind and support poll-history and due-work queries.
- `LifecycleScheduling` provides permission-gated schedule, replace, cancel,
  and list operations with a one-minute lead time and one-year horizon.
- Opening and closing order is validated whenever either transition is created
  or replaced.
- Configuration changes append semantic audit events without storing job
  arguments, actor details, credentials, or voter data.
- Replacement preserves the cancelled record and its already-enqueued job;
  execution-time state filtering safely cancels that stale job.
- The Phase 1 migration removes any poll-free Phase 0 probe rows because they
  cannot be converted into valid production lifecycle commands.

The generated worker still only completes the transition record and does not
change the poll. Phase 2 replaces that proof action with real, classified
lifecycle execution.

### Phase 2 — Real lifecycle execution

- Connect `:execute` to existing Poll open/close actions.
- Add skip/failure classification and final-error handling.
- Preserve lifecycle timestamps and PubSub.
- Add retry, idempotency, race, and privacy tests.

### Phase 3 — Lifecycle UI

- Add Overview/Lifecycle routes and page.
- Present readiness, UTC scheduling, replacement, cancellation, and history.
- Move manual Open/Close out of Results.
- Add permission-aware LiveView tests.

### Phase 4 — Dashboard, audit, and monitoring

- Show next transitions and failed work on the dashboard.
- Complete audit humanization and filtering.
- Add bounded telemetry and safe Oban Web diagnostics.

### Phase 5 — Production hardening

- Verify overdue/restart behavior on Fly.io staging.
- Document always-running worker availability.
- Exercise anonymous and identified polls end to end.
- Audit all persisted/rendered surfaces for sensitive information.
- Roll out behind configuration and update roadmap status.

## Go/no-go criteria

Proceed after Phase 0 only if generated jobs work with AshSQLite and
`Oban.Engines.Lite`, locking is understood, arguments satisfy privacy rules,
cancellation/repetition are safe, module names survive refactors, tests remain
clear, existing workers are unaffected, and operations are visible in Oban
Web.

Otherwise use the documented handwritten-worker alternative. Do not combine
an AshOban scheduler and custom worker for the same transition without a
specific documented ownership boundary.

## Acceptance criteria

The feature is complete when administrators can schedule, replace, and cancel
valid transitions; AshOban-generated workers execute existing lifecycle actions
without a custom lifecycle worker; retries, races, stale work, and cancellation
cannot apply an incorrect transition; state and failures are visible outside
Oban Web; audit attribution is clear; closing never publishes results;
anonymous and identified polls behave consistently; no sensitive voter data
enters jobs or diagnostics; and all compatibility, domain, authorization,
audit, privacy, LiveView, migration, and deployment tests pass.

## Open questions

1. What execution-delay threshold should production telemetry alert on?
2. Should execution restore the administrator or use a system actor?
3. Does AshSQLite support default AshOban locking adequately?
4. Should opening failure automatically cancel its close transition?
5. Should future time zones be installation-wide or administrator-specific?

## Related documentation

- [AshOban documentation](https://ash-oban.hexdocs.pm/readme.html)
- [AshOban triggers and scheduled actions](https://ash-oban.hexdocs.pm/triggers-and-scheduled-actions.html)
- [Email invitation delivery specification](email-invitation-delivery-spec.md)
- [Administrator audit trail specification](admin-audit-trail-spec.md)
- [Fly.io deployment guide](flyio-deployment.md)
