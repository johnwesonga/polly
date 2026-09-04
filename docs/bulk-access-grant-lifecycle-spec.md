# Bulk Voting-Link Revocation and Reissue — Technical Specification

## Status

Specified. Polly currently supports revoking, issuing, and reissuing one
member's access grant at a time from the Voter Access page. Bulk operations
have not been implemented.

## Summary

Allow authorized administrators to revoke or reissue voting access for a
reviewed set of eligible members in one operation. The feature is intended for
credential exposure, delivery mistakes, electorate-wide resets, and other
access incidents where processing members individually is too slow.

The workflow uses Polly's protected voter credentials. It never displays,
exports, logs, or places a working credential in browser or Oban state. Bulk
reissue invalidates each selected member's active grants and creates one new
derived credential per member. Sending replacement invitations is a separate,
explicit step so access mutation never causes an unexpected email campaign.

## Complexity assessment

This is a **medium-to-high complexity** feature. The individual grant actions
already exist, but safely applying them to a large, paginated set requires
clear selection semantics, a trustworthy preview, transactional behavior,
idempotency, bounded workloads, aggregate auditing, and coordination with
pending invitation jobs.

The highest-risk failure would leave only part of an electorate rotated while
the administrator believes the whole operation succeeded. Other risks include
accidentally revoking the wrong filtered result set, sending replacement mail
without intent, allowing stale invitation jobs to deliver invalid links, and
leaking credential material through diagnostics.

## Goals

- Revoke active grants for explicitly selected eligible members.
- Reissue one replacement grant for each selected eligible member.
- Support explicit rows, the current page, and all matching filtered records.
- Preview affected, unchanged, and skipped counts before mutation.
- Re-resolve and validate the selection at confirmation time.
- Apply a confirmed operation atomically within a documented size limit.
- Make retries idempotent through an operation identifier.
- Immediately invalidate old credentials after a successful commit.
- Safely reject invitation jobs pinned to old grants or credential versions.
- Record one useful aggregate audit event rather than thousands of row events.
- Keep replacement delivery separate and permission-aware.
- Work consistently for identified and anonymous polls.

## Non-goals

- Showing, copying, downloading, or reconstructing voting credentials.
- Removing members from the electorate.
- Deleting grants, invitation deliveries, ballots, participations, or audit
  history.
- Allowing a reissued credential to bypass one-final-ballot enforcement.
- Automatically emailing replacement links after reissue.
- Undoing a completed revocation or making an old credential valid again.
- Changing poll options, privacy mode, selection rules, or lifecycle.
- Reissuing access across multiple polls in one operation.
- Arbitrarily uploading grant IDs through CSV in the first iteration.
- Processing an unbounded electorate in one SQLite transaction.

## Terminology

- **Active grant** — an access grant with no `revoked_at` value and no elapsed
  `expires_at` value.
- **Revocation** — setting `revoked_at` on every active grant in scope. It does
  not remove eligibility or history.
- **Reissue** — revoking every active grant in scope and creating exactly one
  new derived-credential grant for each qualifying member.
- **Replacement invitation** — a later email delivery for a newly reissued
  grant. It is not part of the reissue transaction.
- **Selection scope** — explicit member IDs, the visible page, or all members
  matching a normalized server-side filter.
- **Operation ID** — a server-generated UUID identifying one confirmed bulk
  mutation and making repeat submission safe.

## Product rules

1. Only eligible members of the selected poll may be affected.
2. Revocation affects every active grant for each selected member and poll,
   not merely the grant ID rendered in one stale row.
3. Reissue first revokes every active grant and then creates exactly one new
   grant for each qualifying selected member.
4. Reissue preserves the current expiry policy. It must not silently copy an
   already elapsed expiry to the replacement grant.
5. A repeated request with the same operation ID returns its original outcome
   and creates no additional grants.
6. Browser-supplied grant IDs, eligibility state, counts, or filter totals are
   never authoritative.
7. The server resolves the selection and recalculates the preview immediately
   before confirmation.
8. A successful operation commits all grant changes and its audit event, or
   rolls everything back.
9. Revoked credentials stop resolving immediately after commit.
10. Pending delivery jobs pinned to a revoked grant or old version send
    nothing when their workers revalidate.
11. Revocation and reissue never modify ballots or participation records.
12. Reissuing access never permits an already-participating member to submit a
    second ballot.
13. Replacement invitations require a separate explicit confirmation and the
    existing `:send_invitations` permission.
14. Both draft and open polls permit bulk grant management. A closed poll may
    permit revocation for incident response and credentialed-result access,
    but reissue is available only when the UI can clearly explain its
    credentialed-results purpose. The initial UI may conservatively disable
    closed-poll reissue.
15. One synchronous operation is limited to 1,000 selected members. Larger
    operations are deferred to a future durable batching design.

## Selection semantics

Reuse the selection model from the bulk electorate specification so Polly does
not introduce two meanings of “Select all”:

```elixir
{:member_ids, [member_id]}
{:filter, normalized_filter, excluded_member_ids}
```

The Voter Access page must distinguish:

- **Select this page** — selects only rows visible on the current keyset page;
- **Select all N matching members** — selects the complete server-side query;
  and
- **Clear selection** — removes the current selection.

An all-matching selection stores a normalized filter and explicit exclusions,
not thousands of IDs in the socket or browser. Changing the filter invalidates
an all-matching selection. Explicit selections may remain across pages, with a
visible total.

Supported filters should include:

- member name or email search;
- current grant state: active, revoked/missing, or expired;
- invitation delivery state; and
- participation state where the role is allowed to view it.

Filtering and selection must never load token digests, nonces, legacy tokens,
or complete voting URLs.

## Preview model

Before confirmation, the server returns safe aggregate information:

```elixir
%{
  operation_id: "...",
  action: :reissue,
  selected_count: 250,
  affected_member_count: 244,
  active_grant_count: 246,
  replacement_grant_count: 244,
  unchanged_count: 0,
  skipped_count: 6,
  skip_reason_counts: %{
    no_longer_eligible: 2,
    inactive_member: 1,
    no_active_grant: 3
  },
  expires_at: nil,
  expires_at_revision: "..."
}
```

The preview may include member names and email addresses for the selected page
when useful for review. It must never return credential fields, voting URLs,
ballot selections, or member-to-choice information.

Suggested classifications:

| State | Revoke | Reissue |
| --- | --- | --- |
| Eligible with active grant | Revoke active grants | Revoke and create one replacement |
| Eligible with multiple active grants | Revoke all | Revoke all and create one replacement |
| Eligible with no active grant | Unchanged | Create one grant if issuance is intended |
| Inactive member | Revoke for safety | Skip by default |
| No longer eligible | Skip and report | Skip and report |
| Already participated | Revoke credential | Reissue only for an explicitly supported result-access case |
| Missing/deleted record | Skip and report | Skip and report |

Whether reissue includes an eligible member with no active grant must be clear
in the action label. The recommended initial behavior is **Rotate active
access**, which affects only members with an active grant. A distinct future
**Issue missing access** operation avoids hiding issuance inside rotation.

## Administrator workflow

### Entry point

Add a bulk-selection mode to `/admin/polls/:poll_id/access`. Existing per-member
controls remain available for small corrections.

The page displays protected-credential guidance:

> Voting credentials remain hidden. Bulk actions change access state but never
> reveal private links.

### Bulk revoke

After selecting members, the administrator chooses **Revoke selected access**.
The confirmation states:

> Revoke voting access for 244 members? Their current emailed links will stop
> working immediately. Eligibility, ballots, participation, and delivery
> history will be retained. This cannot be undone.

The button uses destructive visual emphasis without using “delete.” After
success, selected rows refresh and the page reports affected members and grant
counts.

### Bulk reissue

The administrator chooses **Reissue selected access**. The confirmation states:

> Reissue access for 244 members? Every current link in scope will stop working
> and one replacement credential will be created per member. Replacement links
> will not be emailed automatically.

After success, the UI offers a separate **Review replacement invitations**
action. That action uses the normal invitation preview and confirmation flow,
not a new email implementation.

### Stale preview

If eligibility, grant, participation, or poll state changed after preview, the
server rejects confirmation with **Selection changed; review the updated
preview**. It must not quietly apply materially different counts.

The preview carries a server-generated revision or digest derived from safe
record identifiers and update timestamps. It is not a credential digest and
must not contain sensitive grant attributes.

## Domain design

Introduce a dedicated bulk boundary rather than looping over
`Electorate.revoke/2` or `Electorate.reissue/2` in the LiveView:

```elixir
Polly.Polls.AccessGrants.preview_bulk(poll, selection, action, actor)
Polly.Polls.AccessGrants.apply_bulk(poll, preview, actor)
```

Suggested actions are initially:

```elixir
:revoke_active
:reissue_active
```

The service must:

1. authorize `:manage_access_grants`;
2. load the poll and authoritative eligibility/member/grant state;
3. normalize and bound the selection;
4. reject unsupported lifecycle combinations;
5. calculate a safe preview and revision;
6. on confirmation, recalculate and compare the revision;
7. lock or conditionally update qualifying active grants;
8. revoke all active grants in scope;
9. create at most one replacement grant per qualifying member for reissue;
10. append one aggregate audit event in the same transaction; and
11. persist or return the operation outcome for idempotent repetition.

The LiveView handles form state and presentation only. It never calls Ash grant
actions in an `Enum.each/2` loop.

## Idempotency and operation records

Add a small `Polly.Polls.AccessGrantOperation` resource if reliable retry and
support history cannot be achieved through the audit event alone. Suggested
fields are:

- `id` / operation UUID;
- `poll_id`;
- `action`;
- `requested_by_id`;
- normalized selection kind and a bounded safe selection reference;
- preview revision;
- status: `prepared`, `completed`, or `failed`;
- selected, affected-member, revoked-grant, replacement-grant, unchanged, and
  skipped counts;
- safe skip-reason counts;
- `completed_at`; and
- normal timestamps.

Do not store an unbounded member-ID list in an operation row. For the initial
explicit-selection limit, a separate operation-member table may snapshot IDs
without any credential fields. For all-matching selection, persist the
normalized filter and its safe exclusions or execute from a transactionally
materialized snapshot.

An operation ID has one immutable action and poll. Reusing it with different
parameters is rejected. A completed operation returns its persisted counts
without mutating access again.

## Transaction and concurrency behavior

The confirmed operation uses one repository transaction within the initial
1,000-member limit.

- Every active grant update is conditional on still being active.
- Reissue enforces at most one new active grant per selected member at commit.
- The operation outcome and aggregate audit event commit with the grant rows.
- A concurrent single-member revoke may reduce the affected count and should
  trigger a stale-preview response before mutation.
- Concurrent reissue operations for overlapping members cannot both leave an
  active replacement grant.
- Poll closure racing with confirmation follows the documented lifecycle rule
  and either commits under the allowed state or rejects without partial work.

The existing schema permits historical grants and may permit more than one
active grant per member. The bulk service must handle that legacy state by
revoking all active rows. Consider a partial unique database index on
`poll_id, member_id WHERE revoked_at IS NULL` before relying on a single-active-
grant invariant.

SQLite serializes writes, but correctness must come from transaction and
constraint behavior so the feature remains valid on a future PostgreSQL
deployment.

## Credential protection

Bulk reissue creates credentials through the existing
`SetDerivedVoterCredential` change. The service must not invoke
`AccessGrant.derive_token_for_delivery/1`; only the trusted invitation worker
needs plaintext credentials in memory.

Never select or render these fields in the bulk workflow:

- legacy `token`;
- `token_digest`;
- `credential_nonce`;
- a derived token;
- private voting URL; or
- production voter-token secret.

Operation records, audits, logs, telemetry, error reports, browser parameters,
LiveView assigns, and Oban arguments are subject to the same restriction.

## Invitation-delivery interaction

Revocation immediately makes pending invitation or reminder deliveries for an
old grant unusable. Existing workers already revalidate grant state and pinned
credential version before delivery; bulk tests must prove they cancel or skip
instead of sending.

Bulk reissue does not enqueue mail. If the administrator proceeds to
replacement delivery:

1. the invitation preview loads only newly active replacement grants;
2. the administrator confirms recipient counts and skip reasons;
3. the existing invitation service creates version-pinned deliveries; and
4. workers derive credentials only in memory.

This separation prevents someone with only `:manage_access_grants` from
exercising `:send_invitations`, and makes the operational impact visible before
hundreds of emails are sent.

## Authorization

- Viewing the Voter Access page follows its existing permission rules.
- Previewing, revoking, and reissuing require `:manage_access_grants`.
- Sending replacement invitations additionally requires
  `:send_invitations`.
- Viewing participation filters requires the existing permitted participation
  or results boundary; it must never expose choices.

Authorization is repeated at confirmation. Resource policies are retained as
defense in depth. Any trusted transaction or intentional `authorize?: false`
boundary must be documented in `Polly.Accounts.AuthorizationCoverage`.

## Audit trail

Add aggregate events:

- `poll_access_grants.bulk_revoked`; and
- `poll_access_grants.bulk_reissued`.

Safe metadata includes:

- operation ID;
- selection kind;
- selected-member count;
- affected-member count;
- revoked-grant count;
- replacement-grant count;
- unchanged count;
- skipped count; and
- bounded skip-reason counts.

Do not place member IDs, member names, email addresses, credential fields,
private URLs, or ballot data in aggregate metadata. Existing individual events
remain appropriate for individual actions; bulk operations must not emit one
individual audit event per member.

Humanized copy should read, for example:

```text
revoked voting access for 244 members in “Board election”
reissued voting access for 244 members in “Board election”
```

## Operational limits and performance

The first iteration rejects more than 1,000 selected members with guidance to
narrow the filter. Keep the limit in application configuration rather than the
LiveView.

Preview queries should aggregate in the database and preload only fields used
for the visible rows. Confirmation may process records with bounded
`Ash.bulk_update`/`Ash.bulk_create` operations inside the transaction, provided
resource changes and errors remain observable.

Instrument:

- preview duration and selected count;
- transaction duration;
- revoked and replacement counts;
- stale-preview and constraint-conflict counts; and
- safe terminal failure codes.

Telemetry labels must remain bounded and must not include poll, member, grant,
operation, or credential values.

## Failure handling

- **Stale preview:** write nothing and require a fresh preview.
- **Authorization change:** write nothing and return forbidden.
- **Poll-state change:** write nothing and explain the current lifecycle.
- **Constraint conflict:** roll back and invite a fresh preview.
- **Audit persistence failure:** roll back the grant operation.
- **Unexpected database failure:** roll back and show a generic retry message;
  retain detailed credential-safe diagnostics for operators.
- **Replacement email failure:** grant reissue remains committed; delivery is a
  separate operation and follows existing retry/status behavior.

Never attempt to restore an old credential after a committed revocation. A
recovery action creates a new grant and replacement credential.

## Testing strategy

### Domain tests

- revoke all active grants for each selected member;
- preserve eligibility, historical grants, deliveries, ballots, and
  participations;
- reissue exactly one new grant per qualifying member;
- prove old credentials fail and newly delivered credentials resolve;
- handle members with zero, one, and multiple active legacy grants;
- skip ineligible, missing, and unsupported member states safely;
- enforce lifecycle rules and the operation-size limit;
- reject stale previews without partial writes;
- repeat one operation ID without duplicating work;
- roll back every mutation when one row or audit append fails; and
- prevent overlapping operations from leaving duplicate active grants.

### Invitation tests

- queued old-grant invitation and reminder jobs send nothing after revoke;
- queued old-version jobs send nothing after reissue;
- reissue itself queues no email;
- replacement delivery requires a second confirmation and permission;
- provider retries do not rotate credentials; and
- delivery records contain only safe IDs and pinned versions.

### LiveView tests

- bulk controls appear only for authorized roles;
- selection survives pagination as documented;
- Select this page and Select all matching have distinct outcomes;
- filter changes invalidate all-matching selection;
- previews show counts, skip reasons, and explicit consequences;
- stale confirmation returns to an updated preview;
- success refreshes only authoritative access state; and
- no rendered HTML or event payload contains credential material.

### Audit, privacy, and migration tests

- one aggregate event is emitted per completed operation;
- audit metadata passes the allow list and size limit;
- no per-member audit flood occurs;
- logs, telemetry, operation rows, LiveView state, and errors contain no token,
  digest, nonce, secret, private URL, ballot, or selection data;
- existing grants and deliveries survive any supporting migration; and
- the optional active-grant uniqueness constraint reports and safely handles
  pre-existing duplicate active rows.

## Rollout plan

1. Add query/preview support and measure expected operation sizes without
   enabling mutations.
2. Add aggregate audit definitions, operation idempotency, and domain tests.
3. Enable bulk revocation for owners on small selections.
4. Enable bulk reissue after stale-delivery and credential-leakage tests pass.
5. Add all-matching filtered scope after explicit cross-page selection is
   stable.
6. Enable permitted administrator roles and monitor conflicts, duration, and
   replacement-delivery failures.

Because revocation is irreversible, there should be no feature-flag rollback
that pretends committed old credentials can be restored. Disabling the feature
only hides new bulk operations; historical changes remain authoritative.

## Implementation phases

### Phase 0 — Query model and safe preview

- Add normalized selection and filter representations.
- Add domain preview classifications and the 1,000-member limit.
- Add safe preview revisions and permission checks.
- Cover pagination, filters, legacy duplicate grants, and credential leakage.

No grants are mutated in this phase.

### Phase 1 — Atomic bulk revocation

- Add operation IDs and idempotent outcome storage.
- Revoke every active grant in scope in one transaction.
- Add the aggregate revocation audit event.
- Verify old invitation/reminder jobs cannot send.
- Add rollback, concurrency, and authorization tests.

### Phase 2 — Atomic bulk reissue

- Create one protected replacement grant per qualifying member.
- Add or enforce the single-active-grant invariant.
- Add the aggregate reissue audit event.
- Prove old credentials fail and no email is implicitly queued.
- Add retry and overlapping-operation tests.

### Phase 3 — Administrator UI

- Add access-page bulk selection across keyset pages.
- Add explicit page/all-matching semantics and selected counts.
- Add preview and confirmation overlays for revoke and reissue.
- Refresh status after completion without leaking credential fields.
- Add role-aware LiveView coverage.

### Phase 4 — Replacement-delivery handoff

- Add **Review replacement invitations** after reissue.
- Reuse existing invitation preview, queue, status, and Oban worker behavior.
- Keep delivery as a separately authorized and confirmed operation.
- Test skipped recipients, stale versions, retries, and partial provider
  failures.

### Phase 5 — Hardening and rollout

- Add telemetry and operator diagnostics.
- Exercise identified and anonymous polls end to end.
- Audit database rows, jobs, logs, errors, telemetry, and HTML for secrets.
- Validate the production transaction limit on Fly.io SQLite.
- Complete the staged rollout and update roadmap status.

## Acceptance criteria

The feature is complete when:

- authorized administrators can preview and confirm bulk revoke or reissue for
  explicit, page, and all-matching selections;
- old credentials stop resolving immediately after a committed operation;
- reissue leaves exactly one active protected grant per qualifying member;
- repeated or overlapping requests cannot create duplicate replacements;
- failed operations make no partial access changes;
- eligibility, ballots, participations, delivery history, and audit history are
  retained;
- reissue sends no email until a separately permitted confirmation;
- stale invitation and reminder jobs never deliver invalid credentials;
- aggregate audit and telemetry explain outcomes without member or credential
  data;
- the UI never retrieves or renders a working credential; and
- all domain, concurrency, authorization, audit, invitation, privacy,
  migration, and LiveView tests pass.

## Open questions

1. Should reissue initially affect only members with an active grant, or also
   issue access to eligible members whose grant is missing?
2. Should closed-poll reissue support recovery of credentialed result access,
   or remain disabled until that workflow is designed separately?
3. Is 1,000 members a suitable synchronous limit for the current Fly.io
   Machine and SQLite volume?
4. Should all-matching operations require typing the poll title for additional
   confirmation?
5. Should replacement invitation review preselect every successfully reissued
   member, or require a new explicit selection?

## Related documentation

- [Voter credential protection specification](voter-credential-protection-spec.md)
- [Bulk electorate selection specification](bulk-electorate-selection-spec.md)
- [Email invitation delivery specification](email-invitation-delivery-spec.md)
- [Reminder email specification](reminder-email-spec.md)
- [Anonymous choices specification](anonymous-choices-spec.md)
- [Administrator audit trail specification](admin-audit-trail-spec.md)
