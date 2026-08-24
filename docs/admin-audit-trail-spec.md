# Administrator audit trail feature specification

## Summary

Add an append-only audit trail for consequential administrator actions. The
trail answers who changed what, when it changed, which record was affected, and
the safe operational context surrounding the change.

Audit events are application records, not ordinary logs. Administrators may
search and inspect them, but application code exposes no update or delete
actions for audit records.

## Complexity assessment

This feature is **medium to high complexity** because it crosses nearly every
administrative write path and must remain trustworthy during transactions,
failures, retries, and future feature development.

The event resource and read-only interface are straightforward. The difficult
parts are:

- guaranteeing that a successful business change and its audit event commit
  together;
- preventing duplicate events when actions retry;
- defining safe metadata without leaking access tokens or personal data;
- representing multi-record operations as one understandable event; and
- preventing future write paths from bypassing the audit boundary.

The feature is manageable if implemented incrementally, beginning with poll
lifecycle and access-control actions before covering lower-risk configuration
edits.

## Goals

- Give administrators a reliable history of consequential changes.
- Make poll lifecycle, publication, electorate, and access-link decisions
  attributable.
- Support operational investigation without searching unstructured logs.
- Keep audit metadata useful while minimizing personal and secret data.
- Establish one reusable audit boundary for future features such as CSV member
  import and expanded poll duplication.

## Non-goals

- Recording every page view, search, filter, or read operation.
- Recording member ballot selections in the administrator audit trail.
- Replacing application logs, metrics, tracing, or error monitoring.
- Providing database-operator-proof or cryptographically signed records.
- Capturing passwords, authentication tokens, access-grant tokens, raw CSV
  contents, or complete before-and-after resource snapshots.
- Building a general event-sourcing system from which application state is
  reconstructed.
- Allowing administrators to restore or undo an action directly from an audit
  event.

## Trust model

The audit trail is append-only at the application layer:

- the audit resource has create and read actions only;
- no administrator interface provides edit or delete controls;
- ordinary application actors cannot create arbitrary audit events directly;
  and
- audited domain operations create events through an internal API.

A database operator with direct file or database access can still alter SQLite
data. Cryptographic chaining, external immutable storage, and compliance-grade
tamper evidence are deferred. The interface must describe the trail as an
application audit history, not an immutable legal record.

## Event model

Add a dedicated audit domain and resource conceptually equivalent to:

```text
Polly.Audit
└── Polly.Audit.Event
```

Suggested event fields:

- `id`: UUID;
- `action`: stable event name string;
- `actor_id`: administrator user ID;
- `actor_label`: administrator email snapshot;
- `target_type`: stable resource type string;
- `target_id`: target resource UUID when one exists;
- `target_label`: short human-readable label snapshot;
- `poll_id`: related poll UUID for poll-scoped filtering;
- `metadata`: constrained JSON-compatible map;
- `source`: action origin such as `admin_ui`, `operator_task`, or `system`;
- `request_id`: optional request correlation identifier;
- `occurred_at`: UTC timestamp; and
- `inserted_at`: persistence timestamp.

`occurred_at` records when the business action completed. `inserted_at` records
when the event row was stored; they should normally be nearly identical.

### Actor snapshots

`actor_id` links to the administrator account when it still exists.
`actor_label` preserves attribution if the account is later renamed or removed.
The snapshot is never used for authorization.

The initial application has no user-deletion workflow. If deletion is added,
the foreign key must restrict deletion or become nullable without cascading
away audit history.

### Target snapshots

`target_type` and `target_id` identify the primary affected record.
`target_label` preserves useful context if the record is later renamed. Examples
include a poll title, option label, or member name.

Audit events must not depend on loading the current target to render their basic
meaning.

### Action names

Actions use stable, namespaced strings rather than an enum so new event types
do not require a database migration. Initial names include:

```text
member.created
member.updated
member.activated
member.deactivated

poll.created
poll.updated
poll.duplicated
poll.opened
poll.closed
poll.results_published

poll_option.created
poll_option.updated
poll_option.reordered
poll_option.deleted

poll_electorate.member_added
poll_electorate.member_removed

poll_access_grant.issued
poll_access_grant.revoked
poll_access_grant.reissued
```

Future event names reserved by planned features may include:

```text
member_import.completed
poll.duplicated_with_configuration
```

Event names are an API contract. Renaming an application module must not rename
historical event actions.

## Event catalog

### Member administration

`member.created` records the new member ID and label.

`member.updated` records an allowlisted `changed_fields` list. It must not store
the old or new email address in metadata because the target label and actor
context are sufficient for the initial operational need.

`member.activated` and `member.deactivated` are separate events rather than a
generic update because activation affects future electorate selection.

### Poll configuration and lifecycle

`poll.created` records creation of a new draft.

`poll.updated` records safe changed fields such as `title`, `description`, and
`slug`, but not full old/new descriptions.

`poll.duplicated` targets the new poll and records:

- `source_poll_id`;
- `source_poll_label`;
- `options_copied`;
- `members_copied`; and
- `members_skipped`.

`poll.opened`, `poll.closed`, and `poll.results_published` record explicit
lifecycle decisions. The existing lifecycle timestamps remain the source of
current poll state; the audit events explain who performed each transition.

### Options

Option events include the owning `poll_id`. Create, update, and delete events
target the option. A reorder event records the option ID and its old and new
positions without recording unrelated option data.

### Electorate

Electorate events identify the poll and member IDs. They do not store member
email addresses or access tokens.

Bulk electorate changes should produce one summary event when performed as one
administrator operation, with counts and bounded ID lists if necessary. They
must not create thousands of redundant UI-level events unless each row is an
independent domain action.

### Access grants

Issue, revoke, and reissue events identify the grant, poll, and member. They
must never contain:

- the grant token;
- any voting URL containing the token;
- token prefixes or hashes intended for display;
- session tokens; or
- password or magic-link data.

For reissue, record the old grant ID and new grant ID. The token values remain
secret and absent.

## Successful versus failed actions

The audit trail records successful, committed administrative state changes.
Validation failures, forbidden actions, and rolled-back transactions do not
create success events.

Failed authentication attempts, suspicious token use, and authorization
denials belong to a separate security-event or operational logging feature.
Mixing them into the administrative change trail would make transaction
semantics and retention rules ambiguous.

If the product later requires attempted-action auditing, add explicit event
outcomes and a separate non-transactional ingestion path rather than treating a
failed attempt as a committed business event.

## Transaction semantics

For a trustworthy event history, the business mutation and its audit event must
share one transaction whenever the data layer supports it:

- if the business mutation rolls back, its audit event rolls back;
- if the required audit event cannot be written, the business mutation rolls
  back; and
- a retry produces at most one committed event for one committed operation.

Ash changes or domain services should append events before transaction commit.
An `after_transaction` callback is too late for required audit records because
the business change may already be committed.

Multi-record services such as electorate inclusion, grant reissue, member CSV
import, and configuration duplication write their summary audit event inside
the same repository transaction as all related records.

### Idempotency

Each audited operation receives an internal `operation_id` UUID. Audit events
have a unique identity on `operation_id`. A retried request reuses the same ID
when possible so the database prevents duplicate events.

LiveView event parameters must not be trusted to supply an operation ID. It is
generated on the server when the operation begins and passed through internal
action context.

## Internal API

Audit creation is exposed only through internal application code, conceptually:

```elixir
Polly.Audit.append!(%{
  operation_id: operation_id,
  action: "poll.opened",
  actor: actor,
  target: poll,
  poll_id: poll.id,
  metadata: %{},
  context: audit_context
})
```

The API must:

1. require an actor for administrator actions;
2. validate `action`, `target_type`, and metadata against an event definition;
3. derive actor and target snapshots server-side;
4. reject forbidden metadata keys and non-JSON-compatible values;
5. redact unexpected sensitive values defensively; and
6. participate in the caller's transaction.

Do not expose a generic public Ash create action that accepts arbitrary actor
IDs, labels, or metadata from browser parameters.

## Audit context

The web layer may attach a small, optional context:

```elixir
%{
  source: "admin_ui",
  request_id: request_id
}
```

IP address and user agent are excluded from the initial database event because
they increase privacy and retention obligations. They may remain in normal
short-lived request logs. Add them later only with an explicit security and
retention requirement.

Operator Mix tasks use `source: "operator_task"`. Truly automatic operations
use `source: "system"` and an explicit system actor representation rather than
pretending an administrator performed them.

## Metadata policy

Metadata is allowlisted per event action. Common permitted values include:

- changed field names;
- old and new lifecycle statuses;
- source and destination record IDs;
- old and new option positions;
- aggregate created, skipped, or affected counts; and
- boolean configuration choices.

Metadata must not contain:

- passwords or password hashes;
- access, session, confirmation, reset, or magic-link tokens;
- complete voting URLs;
- raw CSV rows or file contents;
- arbitrary request parameters;
- full resource dumps;
- email message bodies; or
- ballot selections tied to individual members.

Metadata size is capped at 16 KB after JSON encoding. Larger operational data
belongs in a purpose-built record, not an audit event.

## Administrator interface

Add an authenticated route:

```text
/admin/audit
```

The page appears in administrator navigation as **Audit trail**.

### List view

The default view shows newest events first with:

- timestamp;
- actor label;
- human-readable action;
- target label and type;
- related poll when present; and
- a detail control.

Use a LiveView stream and keyset pagination rather than assigning the complete
history to the socket.

### Filters

The initial filters are:

- date range;
- actor;
- action category;
- target type; and
- poll.

Filters are encoded in URL query parameters so an investigation can be linked
or revisited. Applying filters resets the event stream.

### Detail view

An event detail panel or route displays:

- exact timestamp and event ID;
- actor ID and snapshot label;
- action name and human-readable explanation;
- target and poll identifiers;
- source and request ID; and
- formatted allowlisted metadata.

Unknown future action names remain renderable with a generic fallback rather
than breaking historical pages.

No edit, delete, replay, or undo controls are present.

## Human-readable event copy

UI copy is derived from action definitions, for example:

```text
alex@example.com opened “2027 Team Theme”
alex@example.com revoked access for “Jamie Rivera” in “Board Election”
alex@example.com duplicated “Annual Theme” as “Copy of Annual Theme”
```

Stored events retain stable action names and structured fields. Full English
sentences are not stored because copy can improve without rewriting history.

## Authorization

- Every audit route requires an authenticated administrator.
- In the current first-release model, every application user may read the audit
  trail because every user is an administrator.
- The event create action is internal and unavailable through generic UI or API
  parameters.
- No application actor receives update or destroy authorization for events.
- Future role-based access should separate `audit:read` from ordinary poll
  management because the trail exposes organization-wide activity.

## Retention and deletion

The initial policy retains audit events indefinitely because Polly has no
automated retention system and election history is intentionally retained.

Deleting or archiving a poll, member, option, grant, or administrator must not
cascade-delete audit events. Snapshot labels and scalar IDs allow the trail to
remain understandable without live relationships.

A configurable retention or export policy may be added before handling data
subject to contractual or regulatory deletion requirements. Such a policy must
define whether personal snapshot labels are anonymized while structural events
remain.

## Performance

- Index `occurred_at`, `actor_id`, `action`, `target_type`, `target_id`, and
  `poll_id` according to query needs.
- Use keyset pagination with a stable `occurred_at` plus `id` ordering.
- Audit-list reads must never load full target resources per row.
- Metadata filtering is deferred; SQLite JSON scans are unnecessary for the
  initial interface.
- Appending one audit record should be a small constant addition to each
  administrative transaction.

## Accessibility and responsive behavior

- Filters have visible labels and keyboard-operable controls.
- The event list uses semantic time elements and descriptive action text.
- Actor, action, and target are available as text rather than color alone.
- Pagination and filter changes preserve logical focus.
- Metadata uses a definition list or accessible table, not an unlabelled JSON
  dump.
- On narrow screens, each event becomes a readable stacked record without
  requiring horizontal scrolling for primary information.

## Operational behavior

Unexpected audit failures must be logged without sensitive event metadata. For
required audited actions, the administrator sees that the operation could not
be completed and the business change remains rolled back.

The system should emit a metric for audit append failures. It must not silently
fall back to an unaudited successful write.

## Delivery plan

### Iteration 1 — foundation and critical actions

- Add the Audit domain and append-only Event resource.
- Add event definitions and metadata validation.
- Audit poll creation, updates, duplication, open, close, and publication.
- Audit electorate inclusion/removal and grant issue/revoke/reissue.
- Add the authenticated audit list and event detail view.
- Add transaction, authorization, redaction, and lifecycle tests.

### Iteration 2 — complete administrator coverage

- Audit member create/update/activation changes.
- Audit option create/update/reorder/delete.
- Audit bulk member import and expanded poll duplication.
- Add filters, keyset pagination, and operational metrics.
- Perform a write-path inventory proving every administrator mutation is
  covered or explicitly exempted.

### Iteration 3 — hardening if required

- Export audit history.
- Add retention and anonymization tooling.
- Add separate attempted-action security events.
- Evaluate cryptographic chaining or external append-only storage.

## Testing requirements

### Resource and authorization tests

- creates a valid event only through the internal append boundary;
- rejects missing actors for administrator events;
- exposes no update or destroy actions;
- prevents arbitrary actor and target snapshots from browser input;
- preserves events when target records are absent; and
- denies every audit route to signed-out visitors.

### Transaction tests

- a successful audited mutation commits exactly one event;
- a failed mutation creates no event;
- an audit append failure rolls back the business mutation;
- a multi-record operation and summary event commit atomically;
- retries with one operation ID create at most one event; and
- concurrent operations create distinct correctly attributed events.

### Event catalog tests

- every declared action accepts only its allowlisted metadata;
- lifecycle events contain the expected old and new statuses;
- duplication records source and destination IDs and copy counts;
- grant events contain IDs but no token or URL values;
- changed-field lists exclude secrets and full personal values; and
- all current administrator mutation actions are present in a maintained
  coverage inventory.

### LiveView tests

- renders newest events first using stable DOM IDs;
- renders human-readable copy for every known event action;
- renders an unknown action through the generic fallback;
- filters by actor, category, target, poll, and date;
- filter changes reset the stream and update the URL;
- paginates without duplicating events; and
- event detail renders safe metadata with no mutation controls.

## Acceptance criteria

The initial audit trail is complete when every critical poll lifecycle,
duplication, electorate, and access-grant mutation produces exactly one safe,
attributed event in the same transaction as the business change; failed or
rolled-back mutations produce no success event; authenticated administrators
can inspect the history; and no access token, password, raw CSV content, or
individual ballot selection is stored in audit metadata.

## Likely implementation issues

1. **Retrofitting scattered writes.** Some mutations currently occur directly
   in LiveViews while others live in domain services. Auditing should move
   orchestration into consistent domain boundaries rather than adding UI-only
   logging.
2. **Transaction boundaries.** Hooks that run after commit cannot provide
   atomic auditing. Each action needs review to locate the correct in-transaction
   append point.
3. **Duplicate events.** LiveView retries, database retries, and nested services
   can append the same semantic event twice without operation IDs and clear
   ownership.
4. **Over-collection.** Full changesets and request parameters are convenient
   but risk storing tokens and unnecessary personal data indefinitely.
5. **Multi-record semantics.** Grant reissue and electorate changes can produce
   several low-level writes for one administrator intent. The audit event should
   represent the intent, not every implementation detail.
6. **Actor context.** Operator tasks and future automated jobs need explicit
   attribution rather than bypassing audit or fabricating a user.
7. **Historical relationships.** Foreign-key cascades can accidentally erase
   the trail. Scalar snapshots and restrictive/nullifying relationships require
   deliberate migration design.
8. **Coverage drift.** New administrator actions can ship without audit events
   unless code review, tests, and an event inventory make auditing part of the
   feature definition of done.
9. **SQLite deployment limits.** Audit writes add contention to the same SQLite
   database used for ballots and administration. Measure write latency and
   revisit the database architecture before multi-node or high-volume use.

## Deferred decisions

- Whether audit visibility requires a separate administrator permission.
- Whether actor email snapshots should be anonymized after account deletion.
- Whether IP address retention is justified for security investigations.
- Whether compliance requirements demand external tamper-evident storage.
- The final retention duration if indefinite retention becomes inappropriate.
- Whether successful administrator sign-in and sign-out belong in this trail or
  a separate security activity view.
