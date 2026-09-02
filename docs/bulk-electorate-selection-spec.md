# Bulk Electorate Selection — Technical Specification

## Status

Specified. Polly currently provides immediate **Select all active** and
**Unselect all** controls, but they execute one member at a time and offer no
filtering, preview, scoped selection, or single transactional bulk boundary.
This specification replaces those basic controls with an explicit, scalable,
and auditable bulk workflow.

## Summary

Allow administrators to add or remove many members from a draft poll's
electorate in one reviewed operation. Administrators can filter the roster,
select individual rows or a complete filtered result set, preview the effect,
and confirm one transactional change.

Bulk selection changes eligibility and its associated access-grant lifecycle;
it does not submit ballots, send invitations, or alter the reusable member
roster. The workflow remains limited to draft polls because electorate
membership is frozen when voting opens.

## Complexity assessment

This is a **medium-complexity** feature.

Checkboxes and pagination are straightforward. The important complexity is in
defining whether “all” means the visible page or every filtered result,
preserving selection across LiveView patches, validating stale previews,
updating eligibility and access grants atomically, avoiding thousands of
individual audit events, and handling concurrent administrators safely.

The feature becomes high complexity if selection is extended to saved groups,
external directories, scheduled synchronization, or open polls. Those
capabilities are outside this specification.

## Goals

- Reduce the effort required to configure a large poll electorate.
- Make page-level and filtered-result selection semantics unambiguous.
- Preview additions, removals, unchanged members, and rejected members.
- Apply the confirmed change in one repository transaction.
- Preserve eligibility, access-grant, audit, and poll-lifecycle invariants.
- Keep selections stable while navigating roster pages.
- Make repeated requests safe and idempotent where possible.
- Avoid exposing voter credentials during any bulk operation.

## Non-goals

- Creating, editing, importing, or deactivating roster members.
- Sending invitations as part of electorate selection.
- Viewing, copying, exporting, or deriving voting credentials.
- Modifying the electorate after the poll opens.
- Deleting ballots or historical invitation deliveries.
- Saved electorate presets, member groups, or tags.
- Synchronizing membership with an external directory.
- Applying one bulk operation to multiple polls.
- Automatically selecting every future member matching a filter.

## Product rules

1. Only draft polls permit electorate changes.
2. Only active members may be added to an electorate.
3. Existing eligible members are unchanged when added again.
4. Removing an eligible member revokes every active access grant for that
   member and poll before destroying the eligibility record.
5. Removing a member does not delete old grants, delivery history, or audit
   history.
6. One confirmed operation either commits completely or makes no changes.
7. Selection state contains member IDs only; browser-supplied eligibility or
   grant IDs are never trusted.
8. The server revalidates the member set and poll status at confirmation time.
9. Bulk actions never send invitations implicitly.
10. Opening a poll concurrently with confirmation causes the bulk operation to
    fail without partial writes.

## Selection semantics

The UI must distinguish three concepts:

- **Selected rows** — explicit member IDs chosen by the administrator.
- **Current page** — the visible page of the filtered roster.
- **All filtered results** — every member matching the current server-side
  filter, including records on other pages.

The label **Select all** is too ambiguous for a paginated list. Use explicit
actions:

- **Select this page**
- **Select all N matching members**
- **Clear selection**

The selection summary states both the selected count and scope, for example:

```text
15 members selected on this page
247 matching members selected across all pages
```

Selecting all filtered results represents a server-owned query snapshot, not a
list of thousands of IDs sent to the browser. The server stores the normalized
filter and an exclusion set for rows the administrator subsequently unchecks.

For the first implementation phase, explicit member-ID selection across pages
is sufficient. “All filtered results” can follow once server-side filtering is
available.

## Filtering

The electorate roster should support server-side filters for:

- member name or email search;
- active or inactive status; and
- electorate state: all, eligible, or not eligible.

Filters use URL parameters so the view is bookmarkable and browser navigation
works naturally. Example:

```text
/admin/polls/:poll_id/electorate?q=rivera&membership=not_eligible&status=active
```

Changing a filter resets pagination. Explicit row selections may remain when
they are outside the current filter, but the UI must continue showing the total
selected count and provide **Clear selection**. An “all filtered results”
selection is invalidated when its defining filter changes.

Search input should be debounced. Filtering must occur in Ash or the database,
not by enumerating a LiveView stream.

## Administrator workflow

### 1. Browse and select

The existing electorate page remains the entry point. Each active-member row
gets a bulk-selection checkbox in addition to the existing immediate toggle
during the transition period.

The page provides:

- filters and search;
- paginated results;
- Select this page;
- Select all matching members;
- Clear selection; and
- a sticky selection summary with bulk actions.

Inactive members remain visible when allowed by the filter but cannot be added.
Their disabled checkbox includes the explanation “Inactive members cannot be
added to an electorate.”

### 2. Choose an operation

Available operations are:

- **Add to electorate**
- **Remove from electorate**

The actions may operate on a mixed selection. The preview classifies members
that already have the requested state as unchanged rather than failing.

### 3. Preview

Before writing, the server presents a confirmation overlay with:

- selected or matching-member count;
- members that will be added;
- members that will be removed;
- members already in the requested state;
- inactive or missing members that cannot be added; and
- active grants that will be revoked by removal.

The preview must not display or load grant tokens, token digests, nonces, or
private URLs.

Suggested confirmation copy for removal:

> Remove 42 members from this electorate? Their active voting credentials will
> be revoked. No ballots, delivery records, or audit history will be deleted.

### 4. Confirm

Confirmation sends only an operation identifier or normalized selection
description already held in server state. The server re-resolves the member
set, verifies the poll is still a draft, recomputes the preview, and applies
the change transactionally.

On success, the roster, eligible count, row states, and selection state refresh
without returning to the first page unnecessarily.

Example messages:

```text
38 members added; 4 already eligible.
42 members removed; 42 access grants revoked.
```

## Domain design

Introduce a bulk boundary rather than calling the public single-member service
in a loop from the LiveView:

```elixir
Polly.Polls.Electorate.preview_bulk(poll, selection, operation, actor)
Polly.Polls.Electorate.apply_bulk(poll, selection, operation, actor)
```

Where `operation` is `:add` or `:remove`, and `selection` is one of:

```elixir
{:member_ids, [member_id]}
{:filter, normalized_filter, excluded_member_ids}
```

The service returns a structured preview:

```elixir
%{
  operation: :add,
  selected_count: 42,
  add_member_ids: [...],
  remove_eligibility_ids: [],
  unchanged_count: 3,
  rejected: [%{member_id: id, reason: :inactive}],
  grants_to_revoke_count: 0
}
```

`apply_bulk/4` must not trust the preview's classifications. It re-runs the
same resolution inside the transaction and performs only the resulting plan.

### Adding members

For each valid member that is not already eligible:

1. create one `Eligibility`;
2. issue one derived `AccessGrant`; and
3. retain the normal poll/member uniqueness constraints.

The bulk service may use internal helpers shared with `include_member/3`, but
it should not generate one high-level audit event per member in addition to the
aggregate bulk event.

### Removing members

For each selected eligible member:

1. load active grants constrained by poll and member;
2. revoke those grants;
3. destroy the eligibility; and
4. retain all historical grant and delivery rows.

No removal path may delete a ballot. The draft-only invariant means ballots
should not exist, but retaining history is still the safe failure posture.

## Transactions and concurrency

All writes run inside one `Polly.Repo.transaction/1`. Do not use
`Task.async_stream/3` for database mutations in this workflow because separate
processes would not share the transaction.

Database identities remain the final concurrency guards:

- `Eligibility` is unique by poll and member;
- access-grant credentials remain unique; and
- grant revocation is safe to repeat.

If two administrators add overlapping selections concurrently, one operation
may observe identity conflicts. The service should normalize members created by
the competing transaction to unchanged when it can do so safely; otherwise the
whole losing transaction rolls back with a retryable message.

The poll must be checked as draft inside the same transaction used for writes.
A stale browser preview is never authorization to modify a now-open poll.

## Audit trail

Append one aggregate event per confirmed operation:

```text
poll_electorate.members_added
poll_electorate.members_removed
```

Metadata may contain:

- operation ID;
- added or removed count;
- unchanged count;
- rejected count and safe reason counts;
- grants revoked count; and
- whether selection used explicit IDs or a filter.

Do not store member names, email addresses, full ID lists, voting credentials,
or private URLs in audit metadata. Individual target IDs can be investigated
through retained eligibility and access-grant history when necessary.

## Authorization and security

- The LiveView route continues requiring `:manage_electorates`.
- Both bulk service functions independently require an authenticated actor with
  `:manage_electorates`.
- Access-grant creation and revocation remain protected by their existing
  permissions or a documented trusted bulk-service boundary.
- Browser parameters never determine poll status, active-member state,
  eligibility state, or grant ownership.
- Errors must not expose whether an arbitrary member ID belongs to another
  restricted context.
- Logs, telemetry, audit metadata, and rendered previews contain no voting
  credentials.

## Limits and operational safety

Set a maximum of 5,000 resolved members per confirmed operation. Larger result
sets require narrower filters or a future background-job design.

The preview should reject selections above the limit before confirmation.
Transaction duration and affected-row counts should be measured through safe
telemetry without member IDs.

The implementation should use batched reads to resolve members,
eligibilities, and grants. It must avoid one lookup query per selected member,
even if writes remain individual Ash actions inside the transaction.

## Accessibility and responsive behavior

- Every row checkbox has an accessible label containing the member name.
- The selection summary uses an `aria-live="polite"` region.
- Bulk action availability is not communicated by color alone.
- The confirmation overlay has dialog semantics, a labelled title, initial
  focus, Escape cancellation, and restored focus on close.
- Page navigation preserves keyboard focus near the roster heading.
- On narrow screens, selection controls remain adjacent to the member identity.

## Failure states

- Poll is no longer a draft: cancel the operation and refresh the frozen view.
- Selected member was deleted: classify as missing and do not partially write.
- Member became inactive before add: classify as inactive and re-confirm if the
  remaining plan differs from the preview.
- Eligibility changed concurrently: recompute or return a retryable conflict.
- Grant issuance fails: roll back every eligibility and grant change.
- Grant revocation fails: roll back every removal.
- Invalid or expired LiveView selection state: clear it and request reselection.
- Database timeout: preserve the selection and allow a safe retry.

## Testing strategy

### Domain tests

- Preview classifies additions, removals, unchanged, inactive, and missing
  members correctly.
- Adding creates one eligibility and one derived grant per new member.
- Removing revokes active grants before deleting eligibility.
- Repeating an add or remove is idempotent.
- Mixed selections produce the documented counts.
- Any failed grant or eligibility write rolls back the complete operation.
- Open and closed polls reject preview confirmation and writes.
- Concurrent overlapping operations preserve unique eligibility.
- The 5,000-member limit is enforced.

### LiveView tests

- Selection persists across Next and Previous pagination.
- Select this page affects only visible rows.
- Select all matching members clearly indicates cross-page scope.
- Changing filters resets an all-matching selection.
- Clear selection removes visible and off-page selections.
- Add and remove previews display accurate counts.
- Confirmation refreshes eligible counts and row states.
- Cancellation writes nothing.
- Frozen polls render no bulk mutation controls.
- No credential material appears in HTML or confirmation state.

### Audit and authorization tests

- One aggregate event is written for each successful bulk operation.
- Failed and cancelled operations write no success event.
- Audit metadata contains counts but no names, emails, member-ID arrays, or
  credentials.
- Roles without `:manage_electorates` cannot preview or apply bulk operations.
- Authorization-bypass inventory documents any internal bulk boundary.

## Implementation phases

### Phase 0 — Domain bulk boundary

- Add structured preview and apply operations for explicit member IDs.
- Enforce draft status, active-member rules, transactions, and aggregate audit.
- Add rollback, idempotency, and authorization tests.

This phase can be exercised from tests or IEx without changing the UI.

### Phase 1 — Paginated row selection

- Add row checkboxes and selection state to the existing electorate LiveView.
- Preserve selected IDs across keyset page navigation.
- Add Select this page, Clear selection, Add, and Remove actions.
- Present a confirmation overlay using the domain preview.

### Phase 2 — Server-side filtering

- Add name/email, active status, and eligibility-state filters.
- Store filters in URL parameters and reset pagination when they change.
- Keep explicit selection counts visible when selected rows are off-page.

### Phase 3 — All matching results

- Add the server-owned filtered-selection representation.
- Support exclusions without sending every member ID to the browser.
- Enforce the operation-size limit and stale-filter revalidation.

### Phase 4 — Operational polish

- Add safe telemetry and performance tests for large electorates.
- Improve focus management, responsive layout, and conflict messages.
- Remove the old immediate Select All/Unselect All implementation once the new
  workflow covers its use cases.

## Acceptance criteria

- An administrator can add or remove many members through one reviewed action.
- Page and all-filtered selection scopes are explicit.
- Selection remains coherent across pagination and filtering.
- Additions create eligibility and derived grants atomically.
- Removals revoke active grants and retain history atomically.
- Polls that are not drafts cannot be changed.
- Bulk invitation delivery is not triggered implicitly.
- Aggregate counts and audit events are accurate and credential-free.
- Concurrent or failed operations leave no partial electorate changes.
- Existing single-member toggles continue working until deliberately retired.

## Related documentation

- [CSV member upload](csv-member-upload-spec.md)
- [Poll duplication](poll-duplication-spec.md)
- [Email invitation delivery](email-invitation-delivery-spec.md)
- [Voter credential protection](voter-credential-protection-spec.md)
- [Administrator audit trail](admin-audit-trail-spec.md)
