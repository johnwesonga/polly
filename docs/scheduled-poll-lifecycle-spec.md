# Scheduled Poll Opening and Closing — Technical Specification

## Status

Specified. No implementation has started.

## Summary

Allow authorized administrators to schedule a poll to open and close at
specific future times. Polly persists the intended schedule, executes each
transition through durable Oban jobs, and applies the same validation,
authorization boundary, audit history, timestamps, and PubSub notifications as
the existing manual lifecycle actions.

Scheduling does not add new poll lifecycle statuses. A scheduled draft remains
`:draft` until its opening transition succeeds, an open poll remains `:open`
until its closing transition succeeds, and a completed poll remains `:closed`.
The interface presents schedule state separately from lifecycle state.

The first iteration uses explicitly labelled UTC date-times. Installation and
administrator-specific time zones are deferred until Polly has a dependable
time-zone source and daylight-saving-time policy.

## Complexity assessment

This is a **medium-complexity** feature. Creating a future Oban job is simple;
keeping the database, queued jobs, manual actions, edits, deployment behavior,
and administrator expectations consistent is the harder part.

The principal risks are:

- a superseded job applying an old schedule;
- a scheduled opening failing readiness checks;
- a sleeping Fly.io Machine not executing a job on time;
- ambiguous date-times around time-zone or daylight-saving changes;
- concurrent manual and scheduled transitions;
- duplicate execution after retries or deployment; and
- representing a schedule as a lifecycle status and complicating all existing
  status-dependent behavior.

These risks are addressed with version-pinned jobs, execution-time validation,
idempotent workers, explicit UTC input, persisted failure state, and a
deployment readiness check.

## Goals

- Let an administrator schedule a draft poll to open automatically.
- Let an administrator schedule a draft or open poll to close automatically.
- Permit an opening and closing window to be configured together.
- Execute transitions durably across application restarts and deployments.
- Reuse the existing `Poll.open` and `Poll.close` business rules.
- Make pending, completed, cancelled, superseded, and failed schedules visible.
- Allow an authorized administrator to edit or cancel future transitions.
- Reject stale jobs after a schedule is edited, cancelled, or overtaken by a
  manual lifecycle action.
- Attribute schedule configuration and automatic execution in the audit trail.
- Keep voter, ballot, selection, and credential data out of job arguments,
  logs, and schedule records.

## Non-goals

- Automatically publishing results when a poll closes.
- Automatically sending invitations or reminders when a poll opens.
- Recurring polls or recurring schedules.
- Reopening a closed poll or returning an open poll to draft.
- Scheduling option, electorate, privacy, or selection-rule changes.
- Scheduling result publication or public-result visibility.
- Per-administrator time-zone preferences in the first iteration.
- Guaranteeing second-level execution precision.
- Waking a fully stopped Fly.io application without external infrastructure.
- Replacing Oban Web with a schedule management interface.

## Lifecycle model

The existing forward-only lifecycle remains authoritative:

```text
draft ── open ── closed
```

A schedule is an instruction to request one of those transitions later:

```text
draft + pending open_at  ── worker ──> open
open  + pending close_at ── worker ──> closed
```

Result publication remains a separate, explicit administrator action after a
poll has closed.

The UI must not label a draft poll as “scheduled” in place of its `Draft`
status. It may show an additional `Opens Sep 12, 17:00 UTC` badge or schedule
summary.

## Product rules

1. Only a `:draft` poll may receive a scheduled opening.
2. A `:draft` or `:open` poll may receive a scheduled closing.
3. A `:closed` poll cannot be scheduled.
4. Every newly supplied time must be in the future.
5. When both times are present, `close_at` must be later than `open_at`.
6. An open poll cannot receive or retain a future opening.
7. A scheduled opening runs the existing readiness checks at execution time:
   valid selection rules, enough options, compatible limits, and at least one
   eligible member.
8. Configuration may continue while the poll is a draft. Therefore readiness
   is shown when scheduling but is not required until opening executes.
9. A failed opening leaves the poll in draft and does not discard its failure
   details.
10. A failed opening does not automatically cancel a later closing job. If the
    poll is still draft at closing time, that close job is recorded as skipped
    because its lifecycle precondition is no longer valid.
11. Manual opening before `open_at` completes the opening transition and makes
    its queued job stale; a valid scheduled closing remains in effect.
12. Manual closing before `close_at` completes the closing transition and makes
    all remaining lifecycle jobs stale.
13. Editing or cancelling a schedule increments its version so previously
    queued jobs cannot mutate the poll.
14. Automatic transitions are idempotent. Oban retrying a completed or stale
    instruction must be a safe no-op.
15. Scheduling never rotates access grants or exposes voter credentials.

## Time semantics

### First iteration

The form accepts and displays date-times in UTC and labels them visibly, for
example:

```text
Opens: 2026-09-12 17:00 UTC
Closes: 2026-09-19 17:00 UTC
```

The server converts accepted values to `DateTime` and persists
`:utc_datetime_usec`. Browser locale must not silently reinterpret an unlabelled
date-time. The confirmation dialog repeats the normalized UTC values.

A configurable minimum lead time, initially one minute, prevents a schedule
from expiring while its form is being submitted. A configurable maximum
horizon, initially one year, prevents obvious data-entry errors.

### Later iteration

Add an installation or administrator time zone, display both local time and
UTC, and define behavior for ambiguous or nonexistent daylight-saving times.
That iteration should use a maintained time-zone database rather than a fixed
numeric offset.

### Execution precision

Execution is best effort and should normally begin shortly after the requested
time. Product copy must say “scheduled for,” not promise an exact second. Record
both the requested time and actual completion time so operational delay can be
measured.

## Data model

Add a `Polly.Polls.LifecycleSchedule` Ash resource backed by a
`poll_lifecycle_schedules` table. A separate resource is preferred over only
adding timestamps to `Poll` because schedule execution has its own mutable
version, per-transition state, errors, and administrator attribution.

Suggested attributes:

| Attribute | Type | Purpose |
| --- | --- | --- |
| `id` | UUID | Primary key. |
| `poll_id` | UUID | Required poll relationship; one schedule per poll. |
| `open_at` | UTC datetime, nullable | Desired opening time. |
| `close_at` | UTC datetime, nullable | Desired closing time. |
| `version` | integer | Incremented for every edit or cancellation. |
| `open_state` | enum | `not_scheduled`, `scheduled`, `completed`, `cancelled`, `failed`, or `skipped`. |
| `close_state` | enum | Same states as `open_state`. |
| `open_completed_at` | UTC datetime, nullable | Actual successful opening time. |
| `close_completed_at` | UTC datetime, nullable | Actual successful closing time. |
| `open_failure_code` | string, nullable | Safe bounded failure code. |
| `close_failure_code` | string, nullable | Safe bounded failure code. |
| `scheduled_by_id` | UUID | Administrator who last configured the schedule. |
| `inserted_at` / `updated_at` | UTC datetime | Standard timestamps. |

Add a unique identity on `poll_id`. Add indexes supporting pending opening and
closing lookups. Failure fields contain allow-listed codes, never raw exception
messages.

Suggested safe failure codes include:

- `poll_not_draft`;
- `poll_not_open`;
- `selection_rules_invalid`;
- `insufficient_options`;
- `selection_limits_invalid`;
- `no_eligible_members`;
- `schedule_superseded`; and
- `transition_failed`.

The schedule has a `belongs_to :poll` relationship and `Poll` has a
`has_one :lifecycle_schedule` relationship. Deleting a user in the future must
not delete schedule history; administrator accounts are currently disabled
rather than deleted.

No ballot, participation, selection, member, eligibility, access-grant, or
credential identifier belongs in this table.

## Domain boundary

Create a lifecycle scheduling service rather than constructing jobs in a
LiveView:

```elixir
Polly.Polls.LifecycleScheduling.schedule(poll, attributes, actor)
Polly.Polls.LifecycleScheduling.cancel_open(poll, actor)
Polly.Polls.LifecycleScheduling.cancel_close(poll, actor)
Polly.Polls.LifecycleScheduling.fetch(poll, actor)
```

The service must:

1. authorize the administrator for the relevant lifecycle permission;
2. validate the poll state and normalized UTC times;
3. create or update the schedule and increment its version transactionally;
4. insert replacement Oban jobs carrying the new version;
5. append an audit event; and
6. return safe schedule state for presentation.

Job insertion and schedule mutation should share the same repository
transaction where supported. Old jobs do not need destructive deletion for
correctness: version checking makes them stale. A best-effort cancellation may
reduce queue clutter, but it must not be the safety mechanism.

The service accepts only `open_at` and `close_at` from the UI. It owns version,
state, completion, failure, and attribution fields.

## Oban job design

Add `Polly.Polls.LifecycleWorker` on a dedicated low-concurrency queue, for
example:

```elixir
queues: [mailers: 5, poll_lifecycle: 1]
```

One job represents one transition. Its arguments are deliberately small:

```elixir
%{
  "schedule_id" => schedule.id,
  "transition" => "open",
  "version" => schedule.version
}
```

Do not put titles, administrator email addresses, voter data, credentials, or
date-time strings in job arguments. The worker loads authoritative state from
the database.

Before applying a transition, the worker verifies:

- the schedule exists;
- its version matches the job version;
- the transition is still `scheduled`;
- the corresponding requested time has arrived; and
- the poll remains in the required lifecycle state.

It then invokes the same domain transition used by manual actions. The worker
must not reproduce readiness or lifecycle rules in ad hoc SQL.

Worker outcomes:

- `completed` — transition succeeded and actual completion time is recorded;
- `discard`/safe success — job is stale, cancelled, or already completed;
- `skipped` — a manual or earlier transition made the requested transition
  inapplicable;
- `failed` — a deterministic domain validation failed; record a safe code and
  stop retrying; or
- retry — a transient database or runtime failure occurred.

Use bounded attempts and normal Oban backoff. Oban uniqueness is useful for
reducing duplicate jobs, but version and state checks provide correctness.

## Concurrency and transactions

Scheduled and manual actions may race. Correctness relies on database state,
not on which process checks first.

- The transition action retains its current status validation.
- Schedule completion updates must verify the expected schedule version.
- Only one successful forward lifecycle transition is possible.
- If a manual action wins, the worker reloads state and marks its instruction
  skipped or stale.
- If the worker wins, a concurrent manual action receives the existing
  user-facing lifecycle validation error.

SQLite writes are serialized, which helps on the current deployment, but the
design must not depend exclusively on single-process execution. Tests should
exercise repeat execution and stale versions even if true parallelism is
limited by SQLite.

## Authorization and trusted execution

Scheduling and cancelling opening requires `:manage_polls`. Scheduling or
cancelling closing requires `:publish_results`, matching the existing manual
actions. If one request configures both, the actor must hold both permissions.

Authorization is evaluated when an administrator creates or edits a schedule.
The durable worker is a trusted internal executor of that authorized command;
it must not depend on the scheduling account still being signed in when the
time arrives. The schedule retains `scheduled_by_id` for attribution.

The worker boundary and every intentional `authorize?: false` call must be
listed in `Polly.Accounts.AuthorizationCoverage` with a narrow reason.

## Audit trail

Add allow-listed events:

- `poll.lifecycle_scheduled` with changed transition names and requested UTC
  times;
- `poll.lifecycle_schedule_updated` with changed transition names and new UTC
  times;
- `poll.lifecycle_schedule_cancelled` with cancelled transition names;
- `poll.opened_automatically` with requested and actual execution times;
- `poll.closed_automatically` with requested and actual execution times; and
- `poll.lifecycle_schedule_failed` with transition and safe failure code.

Configuration events use the administrator as actor and `admin_ui` as source.
Execution events should preserve the scheduling administrator for historical
attribution while setting source to `scheduled_job`. The UI should phrase this
as “opened automatically from a schedule configured by …” rather than imply
the administrator was present at execution time.

If the audit model later gains a first-class system actor, automatic execution
can use it and retain the scheduling administrator ID as safe metadata.

## Administrator experience

### Location

Lifecycle controls are confusing when presented as result viewing actions.
Introduce a poll **Overview** or **Lifecycle** section accessible from the poll
list and poll detail tabs. Move manual Open and Close controls there as part of
the UI iteration, while keeping Results focused on turnout, aggregates,
publication, and export.

This relocation should be a separate, reviewable UI change; the scheduling
domain must not depend on it.

### Draft poll

The lifecycle panel shows:

- current `Draft` status;
- current readiness checks;
- optional opening and closing date-time inputs labelled `UTC`;
- normalized schedule summary;
- **Schedule lifecycle** confirmation; and
- manual **Open now** action.

If the poll is not currently ready, scheduling is allowed but the confirmation
warns that opening will fail unless the listed issues are resolved before
`open_at`.

### Open poll

The panel shows when the poll actually opened and how long it has been open. It
allows a closing time to be added, edited, or cancelled, and retains **Close
now**.

### Closed poll

The panel shows actual opening and closing times plus schedule history. No new
lifecycle schedule may be created. Result publication remains in Results.

### Confirmation and feedback

Every create or edit confirmation repeats the UTC schedule. Cancellation is
confirmed when it removes an imminent transition. Success messages distinguish
configuration from execution:

```text
Poll opening scheduled for Sep 12, 2026 at 17:00 UTC.
Scheduled closing cancelled. The poll remains open until closed manually.
```

A failed transition produces an Action Required item with a safe explanation
and link to the lifecycle panel. It must never fail silently.

### Poll list and dashboard

Poll cards may show the next pending transition. The dashboard adds:

- upcoming opening and closing items within a useful horizon;
- failed lifecycle schedules under Action Required; and
- links to the poll lifecycle panel.

Do not run per-poll schedule queries from the template. Load schedule summaries
through a bounded dashboard query.

## Voter and result behavior

- Before opening, voting links retain the current draft behavior.
- Successful scheduled opening immediately uses the normal open-poll voting
  behavior and broadcasts the existing status event.
- Successful scheduled closing rejects new submissions through the existing
  closed-poll validation and updates connected LiveViews through PubSub.
- A voter already submitting at the boundary receives whichever result the
  committed database ordering permits; no partially committed ballot is
  created.
- Closing does not publish results.
- Public results remain unavailable until the existing explicit publication
  requirements are met.
- Anonymous and identified polls use exactly the same scheduling boundary.

## Fly.io and operational requirements

Oban persists scheduled jobs in the SQLite database on the Fly volume, so jobs
survive application restarts and deployments. They cannot execute while every
Machine is stopped or suspended.

Before enabling this feature in production, Polly must either:

- keep at least one Machine running (`min_machines_running = 1` and an
  auto-stop policy compatible with that requirement); or
- provide an external wake mechanism with explicitly documented delay and
  reliability characteristics.

The first production iteration should require an always-running Machine. The
deployment guide must call this out because a health check passing during
deployment does not guarantee timely future job execution.

Oban Web remains useful for operators, but it is not the administrator-facing
source of schedule state. Operational telemetry should include:

- scheduled transition count by kind;
- execution delay in milliseconds;
- completed, skipped, stale, failed, and retried counts; and
- safe failure codes.

Alerts must not include job arguments or raw exception text.

## Failure handling

### Readiness failure at opening

Mark the opening transition failed, retain the draft state, record an
allow-listed failure code, append an audit event, emit telemetry, and surface
Action Required. Do not repeatedly retry deterministic validation failures.

An administrator can fix the poll and explicitly choose **Open now** or
schedule a new future opening. Fixing readiness must not silently execute a
previously failed instruction.

### Application unavailable at the requested time

When the application resumes, Oban executes the overdue job. Polly records the
requested and actual times and exposes the delay. It does not skip solely
because the scheduled time passed.

### Database or transient runtime failure

Return an Oban error for retry. Do not mark the schedule terminally failed
until attempts are exhausted. The final attempt records a generic safe failure
code and raises an operational alert.

### Edited or cancelled schedule

The old job observes a version mismatch and exits without modifying the poll.
This is an expected stale outcome, not an administrator-facing error.

## Testing strategy

### Resource and domain tests

- accept a valid future opening, closing, and combined window;
- reject past times and an inverted window;
- reject opening schedules for open or closed polls;
- reject closing schedules for closed polls;
- enforce permission differences between opening and closing;
- increment the version on edit and cancellation;
- retain only safe bounded failure codes; and
- ensure scheduling never changes poll status immediately.

### Worker tests

Use `Oban.Testing` and explicit times rather than sleeps:

- a due opening transitions a ready draft to open;
- a due closing transitions an open poll to closed;
- early execution does not apply a transition;
- duplicate execution is idempotent;
- an old version is discarded;
- a cancelled transition is discarded;
- manual opening makes only the opening job stale and preserves closing;
- manual closing makes pending lifecycle jobs stale;
- deterministic readiness failure is recorded without retrying;
- transient errors retry; and
- jobs contain only schedule ID, transition, and version.

### Audit and privacy tests

- schedule changes are attributed to the administrator;
- automatic events identify their scheduled-job source;
- requested and actual times are present;
- raw exceptions and unauthorized metadata are rejected;
- logs, telemetry, jobs, and rendered HTML contain no voter credentials or
  member-choice data; and
- authorization coverage accounts for the worker and scheduling service.

### LiveView tests

- controls appear only for permitted roles and valid lifecycle states;
- UTC labels and normalized confirmation values are visible;
- validation errors do not crash the LiveView;
- editing and cancelling refresh schedule state;
- manual action confirmations explain their effect on pending schedules;
- failed schedules render Action Required; and
- Results no longer presents opening as a result-viewing concern after the
  lifecycle UI is introduced.

### Deployment tests

- migrations preserve all existing polls;
- scheduled jobs survive an application restart;
- an overdue job executes after restart exactly once;
- a release uses the persisted Fly volume database; and
- deployment documentation verifies the always-running Machine requirement.

## Rollout and observability

1. Deploy the resource, migration, query boundary, and read-only presentation
   with schedule creation disabled.
2. Deploy worker execution and verify restart behavior in staging.
3. Enable scheduling for owners and administrators behind application config.
4. Monitor execution delay, failures, stale jobs, and duplicate attempts.
5. Enable it by default after at least one real opening and closing window is
   observed successfully.

The feature flag controls creation and editing. Existing persisted schedules
must continue to execute when the flag is disabled unless an owner explicitly
cancels them; disabling UI creation must not strand previously authorized
commands.

## Implementation phases

### Phase 0 — State model and migration

- Add schedule and transition-state enums.
- Add `LifecycleSchedule`, relationships, constraints, and migration.
- Add read-only IEx examples for schedules.
- Test defaults, identities, constraints, and preservation of existing polls.

This PR contains no job execution or administrator mutation UI.

### Phase 1 — Scheduling service

- Add authorized create, edit, fetch, and cancel boundaries.
- Normalize and validate UTC inputs.
- Increment versions and enqueue version-pinned jobs transactionally.
- Add schedule configuration audit events.
- Cover permissions, validation, and safe job arguments.

### Phase 2 — Durable lifecycle worker

- Add the dedicated Oban queue and worker.
- Revalidate version, due time, schedule state, and poll lifecycle.
- Call existing open and close transitions.
- Persist completion, skip, and safe failure state.
- Add idempotency, stale-job, retry, and race-condition tests.

### Phase 3 — Poll lifecycle UI

- Add an Overview or Lifecycle section.
- Present readiness, UTC schedule controls, confirmation, edit, and cancel.
- Move manual Open and Close controls out of Results.
- Add permission-aware LiveView coverage.

### Phase 4 — Dashboard, audit, and monitoring

- Show next transitions and failed schedules on the dashboard.
- Complete automatic execution audit presentation.
- Emit execution outcome and delay telemetry.
- Add operational documentation and safe diagnostics.

### Phase 5 — Production hardening and release

- Verify restart and overdue execution behavior.
- Update Fly.io documentation for an always-running Machine.
- Exercise anonymous and identified polls end to end.
- Audit logs, jobs, telemetry, and rendered pages for sensitive data.
- Complete the staged feature-flag rollout and update roadmap status.

## Acceptance criteria

The feature is complete when:

- an authorized administrator can schedule, edit, and cancel valid future
  opening and closing transitions;
- scheduled transitions survive restarts and execute through existing poll
  lifecycle rules;
- stale, duplicate, cancelled, manual-overtaken, and invalid jobs cannot apply
  an incorrect transition;
- administrators can see pending, completed, skipped, and failed state without
  opening Oban Web;
- manual and scheduled transitions produce clear audit history;
- closing never publishes results automatically;
- schedule handling works identically for identified and anonymous polls;
- no schedule artifact contains voter credentials or choice data;
- production cannot enable scheduling without documented worker availability;
  and
- all resource, worker, authorization, audit, privacy, LiveView, migration, and
  deployment tests pass.

## Open questions

1. Should the initial production release accept UTC only, or should an
   installation-wide time zone be required before enabling it?
2. How close to execution should cancellation require an extra confirmation?
3. Should invitation delivery optionally be scheduled relative to opening in a
   later feature, or remain entirely independent?
4. Should a failed opening automatically cancel its later closing instruction,
   instead of allowing that job to record a lifecycle skip?
5. Should operators receive an external notification for terminal schedule
   failures, beyond dashboard and telemetry alerts?
