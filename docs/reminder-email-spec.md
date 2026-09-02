# Reminder Emails — Technical Specification

## Status

Specified. Polly can send initial and resend invitation emails, but it does not
yet provide a dedicated workflow for reminding eligible members who have not
submitted a ballot.

## Summary

Allow authorized administrators to send reminder emails to eligible members
who have not yet participated in an open poll. Reminders reuse Polly's durable
Oban delivery pipeline and protected voter credentials while revealing neither
the member's selections nor aggregate result information.

The first iteration is manually initiated from the Voter Access page. Before
queueing and again immediately before delivery, Polly verifies eligibility,
member activity, recipient email, access-grant validity, poll status, and lack
of participation. Members who vote after a reminder is queued are skipped by
the worker rather than receiving a stale reminder.

## Complexity assessment

This is a **medium-complexity** feature because most delivery infrastructure
already exists. The primary risks are privacy leaks, duplicate or excessive
email, race conditions between queueing and ballot submission, incorrect
participation checks, and confusing reminders with ordinary invitation
resends.

The feature becomes more complex when reminders are scheduled, recurring,
timezone-aware, organization-configurable, or integrated with anonymous
ballots. Those concerns are planned explicitly rather than being hidden in the
first implementation.

## Goals

- Let administrators identify how many eligible members have not voted.
- Send a private reminder without revealing or inferring any selection.
- Reuse the member's current protected voting credential.
- Keep delivery asynchronous, retryable, and observable through Oban.
- Prevent reminders after a member submits a ballot.
- Prevent accidental reminder floods through cooldown and confirmation rules.
- Distinguish reminder history from initial invitations and explicit resends.
- Preserve compatibility with anonymous choices and participation tracking.
- Keep credentials and member-choice data out of jobs, logs, audits, and
  delivery records.

## Non-goals

- Revealing how a member voted.
- Including current leaders, option counts, turnout details, or result links.
- Automatically changing eligibility or issuing new access grants.
- Replacing an invalid credential without administrator intent.
- Sending reminders to inactive, ineligible, or already-voted members.
- Scheduled or recurring reminders in the first iteration.
- SMS, push notifications, or third-party messaging channels.
- Read receipts or proof that a member opened the email.
- Allowing administrators to provide arbitrary email HTML.
- Reminder escalation based on a member's identity or presumed choice.

## Terminology

- **Participation** — whether an eligible member has submitted a final ballot.
- **Non-voter** — an eligible member for whom the participation check is false.
- **Reminder candidate** — a non-voter who also has an active member record,
  deliverable email address, and usable access grant.
- **Cooldown** — the minimum elapsed time before another reminder may be queued
  for the same poll, member, and active grant.
- **Reminder operation** — one administrator-confirmed bulk queue request.

“Non-voter” is internal terminology. Administrator and member-facing copy
should prefer “has not submitted” or “voting is still open.”

## Product rules

1. Reminders may be queued only while the poll is `:open`.
2. The member must still be eligible and active.
3. The member must have a non-empty email address.
4. The member must have a usable, unrevoked, unexpired access grant.
5. The member must not have submitted a ballot.
6. A reminder uses the current grant and credential version; it does not rotate
   or reissue access.
7. One member may receive at most one queued or sending reminder at a time.
8. An accepted reminder starts the configured cooldown period.
9. Provider retries for one delivery are not separate reminders.
10. The worker revalidates every rule before constructing the email.
11. A member who votes after queueing is skipped with `already_voted`.
12. Reminder email content contains no option labels or result information.

## Participation boundary

The targeting logic must use one domain-level participation predicate rather
than duplicating direct `Ballot.member_id` queries across the LiveView,
invitation service, dashboard, and worker.

Conceptually:

```elixir
Polly.Polls.Participation.submitted?(poll_id, member_id)
Polly.Polls.Participation.submitted_member_ids(poll_id)
```

In the current identified-ballot model, these functions query `Ballot` by poll
and member. When anonymous choices are implemented, they must instead query the
separate participation record while leaving anonymous ballots unlinked from
member identity.

Reminder code must never load `Selection` records. Whether a member submitted
is sufficient; what they selected is irrelevant and prohibited from this
workflow.

## Candidate states

The preview classifies every eligible member into one state:

| State | Reminder behavior |
| --- | --- |
| `:ready_for_reminder` | May be queued. |
| `:already_voted` | Skip permanently for this poll. |
| `:inactive_member` | Skip. |
| `:missing_email` | Skip until corrected. |
| `:missing_grant` | Skip until access is issued. |
| `:revoked_grant` | Skip until access is reissued. |
| `:expired_grant` | Skip until access is reissued. |
| `:reminder_in_flight` | Skip while queued or sending. |
| `:reminder_cooldown` | Skip until cooldown ends. |
| `:poll_not_open` | No reminders may be queued. |

An initial invitation is not a prerequisite for a reminder. If the member has
a usable grant but no accepted invitation, the UI should normally offer the
initial invitation action instead of labelling it a reminder. Bulk reminder
targeting should therefore require at least one accepted initial or resend
delivery unless product testing demonstrates a need for reminders as the first
message.

## Cooldown and send limits

Use a conservative default cooldown of 24 hours between provider-accepted
reminders for the same poll, member, and grant. The value should be application
configuration rather than hardcoded in the LiveView:

```elixir
config :polly, :reminder_cooldown, hours: 24
```

The first iteration also limits one bulk reminder operation to 5,000
recipients. Requests above the limit are rejected with guidance to narrow the
electorate or use a future scheduled/batched workflow.

Cooldown uses accepted delivery time, not queue time. A failed reminder may be
retried through its existing Oban job. An explicit new reminder after terminal
failure may be allowed, but the UI must avoid creating concurrent duplicate
jobs.

## Data model

Extend `InvitationDelivery.kind` with:

```elixir
:reminder
```

Existing delivery fields already provide:

- poll, member, and access-grant references;
- credential-version pinning;
- operation and deduplication identifiers;
- recipient email snapshot;
- queue, sending, accepted, failed, and cancelled states;
- attempt counts and safe failure codes; and
- accepted and failure timestamps.

No reminder-specific token, URL, option, ballot, or selection field is added.

If querying the most recent accepted reminder becomes expensive, add an index
covering poll, member, kind, status, and accepted time. Do not add a mutable
`last_reminded_at` value to `Member`; reminders are poll-specific and delivery
history is already the authoritative record.

The dedupe key should identify one grant and reminder operation:

```text
reminder:<operation_id>:<grant_id>:<credential_version>
```

The unique dedupe identity prevents a retry of the queue transaction from
creating duplicate deliveries.

## Domain design

Add reminder operations to the invitation boundary rather than implementing
candidate selection in the LiveView:

```elixir
Polly.Polls.Invitations.preview_reminders(poll, actor)
Polly.Polls.Invitations.enqueue_reminders(poll, actor, options \\ [])
```

`preview_reminders/2` returns aggregate counts and constrained recipient state:

```elixir
%{
  ready_count: 24,
  skipped_count: 76,
  counts: %{
    ready_for_reminder: 24,
    already_voted: 51,
    reminder_cooldown: 20,
    missing_email: 5
  },
  recipients: [...]
}
```

The returned recipient representation must not contain a working token,
credential URL, token digest, or nonce. It may contain the safe grant ID and
credential version needed by the trusted queue boundary.

`enqueue_reminders/3` must:

1. require an authorized actor;
2. verify the poll is open;
3. recompute the preview rather than trusting browser counts;
4. enforce cooldown, in-flight, and operation-size limits;
5. create one `InvitationDelivery` per ready recipient inside one transaction;
6. insert one ID-only Oban job per delivery;
7. append one aggregate audit event; and
8. return queued and skipped counts.

Ordinary validation failures return tagged domain errors rather than raising
through the LiveView.

## Worker behavior

The existing invitation worker remains responsible for durable delivery. For
`:reminder` deliveries it performs the normal checks plus participation and
cooldown revalidation.

Before email construction, the worker verifies:

1. delivery is not already accepted or cancelled;
2. poll is still open;
3. member is active;
4. recipient email has not changed;
5. delivery credential version matches the grant;
6. grant is unrevoked and unexpired;
7. member remains eligible;
8. member has not submitted; and
9. no separate accepted reminder now places it inside cooldown.

If participation now exists, cancel with `already_voted`. If the credential
version changed, cancel with `stale_credential`. These are safe operational
states and should not be retried.

The job arguments continue containing only `delivery_id`. The worker derives
the protected voting credential in memory after all cancellation checks pass.

## Email content

Add a dedicated reminder builder or a mode parameter to the existing
invitation email module. The subject should be recognizable without being
coercive:

```text
Reminder: voting is open for <poll title>
```

Suggested body:

```text
Hello <member name>,

Voting is still open for “<poll title>”. Our records show that you have not yet
submitted a ballot.

Selection rule: <plain-language selection rule>.

Cast your vote: <private URL>

This private link is personal to you. Do not forward or share it. If you have
already voted very recently, no action is required.
```

The email must not contain:

- option labels;
- selections or inferred preferences;
- current results, leaders, or turnout percentage;
- names or participation state of other members; or
- language implying how the member should vote.

Multipart HTML and plain-text bodies remain required. The HTML version follows
the Touchpad visual language and maintains accessible contrast, semantic links,
and a visible private-link warning.

## Administrator workflow

### Voter Access summary

The Voter Access page adds a **Remind non-voters** action near invitation
controls. It displays a summary such as:

```text
24 ready for reminder · 76 skipped
```

The skipped breakdown uses safe reasons such as Already voted, Recently
reminded, Missing email, and Invalid access. It never displays ballot choices.

### Confirmation

The administrator must confirm every bulk reminder operation. The dialog shows:

- number that will be queued;
- number already voted;
- number recently reminded or already in flight;
- other safe skip categories; and
- the cooldown policy.

Suggested warning:

> Queue reminders for 24 members who have not submitted? Participation is
> checked again before each email is sent.

### Status presentation

Per-member delivery history distinguishes:

- Invitation sent;
- Reminder queued;
- Reminder sending;
- Reminder sent;
- Reminder failed; and
- Reminder cancelled because the member already voted.

The existing read-only Oban dashboard continues to provide job-level
diagnostics. Administrators cannot inspect the private URL there because it is
never stored in job arguments.

## Authorization

- Viewing reminder readiness requires `:send_invitations` or the existing safe
  invitation-status permission.
- Previewing and queueing reminders require `:send_invitations`.
- The LiveView remains protected by its access-grant permission and must apply
  the additional send permission to reminder events.
- The worker is a documented trusted boundary operating on an authorized,
  durable command.
- Reminder functionality does not grant permission to inspect ballots or
  selections.

Role tests must verify that administrators without `:send_invitations` cannot
render or trigger reminder actions even if they may view aggregate results.

## Privacy and security

- Participation state is sensitive administrative data even though it does not
  reveal a choice.
- Do not place recipient names, emails, member-ID lists, or participation lists
  in aggregate audit metadata.
- Do not log raw email bodies, private URLs, tokens, digests, or nonces.
- Oban arguments contain only delivery IDs.
- Telemetry includes operation counts and safe status codes, not member IDs.
- Generic public voting errors must not reveal reminder or participation state.
- Reminder emails use the current credential and never create administrator-
  visible credential material.
- CSV exports are outside this iteration and must not add working URLs.

## Audit trail

Append one aggregate event for each confirmed operation:

```text
poll.reminders_enqueued
```

Safe metadata includes:

- operation ID;
- poll ID through the existing event relationship;
- queued count;
- skipped count;
- safe skip-reason counts;
- cooldown duration; and
- request kind `reminder`.

Do not record member names, email addresses, recipient ID arrays, ballot IDs,
selection IDs, option IDs, or credentials.

Individual delivery records provide authorized operational history without
embedding those details in the aggregate audit event.

## Concurrency and race conditions

### Member votes after preview

Queueing recomputes participation. If the member votes after queueing, the
worker cancels before email construction.

### Two administrators send reminders

The queue transaction rechecks in-flight and cooldown state. A database-backed
dedupe identity prevents the same operation from inserting twice. Concurrent
different operations may still race, so candidate resolution and delivery
creation must use a transaction and normalize identity conflicts to
`reminder_in_flight` where possible.

### Credential rotation

Each delivery pins the credential version. Reissue or rotation makes an older
job stale, and the worker cancels it rather than delivering an invalid link.

### Poll closes

Queued reminders cancel with `poll_not_open`. Closing the poll does not require
deleting jobs or delivery history.

## Configuration

Suggested configuration:

```elixir
config :polly,
  reminder_cooldown: [hours: 24],
  reminder_operation_limit: 5_000
```

Production and development may share defaults. These values are operational
configuration, not secrets. Changes affect future preview and queue decisions;
they do not rewrite delivery history.

## Failure states

- Poll not open: reject queueing or cancel a queued delivery.
- Already voted: skip or cancel without sending.
- Reminder in flight: skip as a duplicate.
- Cooldown active: show when another reminder becomes available without
  exposing exact behavioral history unnecessarily.
- Missing or changed email: skip or cancel with a safe reason.
- Revoked, expired, or stale grant: cancel and direct the administrator to the
  existing access lifecycle controls.
- Provider rejection: retain the existing safe provider error category.
- Transaction failure: create no partial reminder operation.
- Oban retry exhaustion: mark the delivery failed without creating a new
  reminder record.

## Accessibility and responsive behavior

- Reminder readiness updates use an `aria-live="polite"` region.
- The confirmation overlay has dialog semantics and a labelled title.
- Counts and skip reasons do not rely on color alone.
- Buttons clearly distinguish initial invitation, resend, and reminder.
- Disabled actions provide visible explanatory copy.
- The email remains usable with images disabled and at narrow widths.
- The private voting link has meaningful link text and a visible URL fallback.

## Testing strategy

### Candidate and domain tests

- An eligible active non-voter with accepted invitation and valid grant is
  ready.
- Already-voted, inactive, missing-email, missing-grant, revoked, expired,
  in-flight, and cooldown candidates are skipped correctly.
- Preview never loads credential or selection fields.
- Queueing revalidates stale preview state.
- Operation limits are enforced.
- Concurrent operations do not create duplicate reminders.

### Worker tests

- A ready reminder derives the pinned credential and sends multipart email.
- A member who votes after queueing receives no reminder.
- Closed poll, changed email, revoked grant, expired grant, stale version, and
  inactive member cancel safely.
- Provider retries reuse the same delivery and credential version.
- Job arguments and inspected delivery records contain no private URL or token.

### Email tests

- Subject and both bodies identify the message as a reminder.
- Selection rules are included without option labels.
- No result, turnout, ballot, or selection details appear.
- HTML retains Touchpad styling and a plain-text alternative.

### LiveView tests

- Reminder summary uses electorate-wide counts across access-list pages.
- Confirmation displays ready and skipped counts.
- Cancellation queues nothing.
- Confirmation queues only newly revalidated candidates.
- Per-member status distinguishes reminders from invitations.
- Unauthorized roles cannot see or trigger reminder controls.
- No rendered HTML contains a working voter credential.

### Audit tests

- One aggregate event is written per successful operation.
- Cancelled and failed queue transactions write no success event.
- Metadata contains safe counts but no recipient identities or voting data.

## Implementation phases

### Phase 0 — Shared participation boundary

- Introduce centralized submitted/member-ID queries.
- Replace direct participation checks in invitation readiness and workers.
- Add identified-ballot tests and document anonymous-ballot compatibility.

No reminder email is sent in this phase.

### Phase 1 — Manual reminder delivery

- Add the `:reminder` delivery kind and migration.
- Add reminder preview and queue service functions.
- Add dedicated reminder email copy.
- Reuse ID-only Oban jobs, version pinning, and worker cancellation checks.
- Add domain, worker, email, authorization, and audit coverage.

### Phase 2 — Administrator presentation

- Add electorate-wide reminder readiness to the Voter Access page.
- Add confirmation and safe skip-reason breakdowns.
- Add reminder-specific per-member status and retry presentation.
- Preserve counts and actions across access-list pagination.

### Phase 3 — Cooldown and concurrency hardening

- Add configurable cooldown and operation limits.
- Add database indexes needed for recent-reminder lookup.
- Normalize concurrent reminder attempts and expand telemetry.
- Add high-volume and race-condition tests.

### Phase 4 — Optional scheduling

- Allow administrators to schedule one future reminder operation.
- Recompute candidates at execution time rather than persisting a recipient
  list.
- Add cancellation, timezone, deployment, and operational controls.

Recurring campaigns remain a separate product decision.

## Acceptance criteria

- Authorized administrators can preview and manually queue reminders for an
  open poll.
- Only eligible, active, deliverable members without participation are queued.
- Participation is checked again before delivery.
- A reminder contains the current private voting link but no option or result
  information.
- Credentials do not appear in database fields, job arguments, logs, audits,
  telemetry, or administrator HTML.
- Duplicate and excessive reminder attempts are constrained.
- Delivery state is distinguishable from initial invitations and resends.
- Aggregate audit history contains no recipient identities or voting choices.
- The participation boundary can switch to anonymous participation records
  without changing reminder behavior.

## Related documentation

- [Email invitation delivery](email-invitation-delivery-spec.md)
- [Voter credential protection](voter-credential-protection-spec.md)
- [Anonymous choices with participation tracking](anonymous-choices-spec.md)
- [Administrator audit trail](admin-audit-trail-spec.md)
- [Bulk electorate selection](bulk-electorate-selection-spec.md)
