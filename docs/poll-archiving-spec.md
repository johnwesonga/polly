# Poll archiving feature specification

## Summary

Allow authenticated administrators to archive completed polls so the normal
poll administration list stays focused on current work while all poll history
remains intact.

Archiving is an administrative visibility state, not a poll lifecycle status.
An archived poll remains `closed`, retains its options, electorate, grants,
ballots, selections, timestamps, and published results, and may be restored to
the normal administration list.

## Complexity assessment

This is a **small-to-medium complexity** feature if archival remains a
reversible visibility control.

The database change and filtered list are straightforward. The main risks are
accidentally treating archive as deletion, changing public result behavior,
hiding a poll from all administrative access, or allowing an open poll to be
archived while voting is still underway.

The feature becomes substantially more complex if archival is expected to
move records to separate storage, revoke access grants, anonymize voters, or
implement a legal retention policy. Those behaviors are explicitly outside
this iteration.

## Goals

- Keep the default poll list focused on drafts, open polls, and recent work.
- Retain the complete historical record for completed polls.
- Let administrators find, inspect, duplicate, and restore archived polls.
- Preserve public result and voter-link behavior after archival.
- Make archival reversible and safe to retry.
- Avoid changing the existing forward-only poll lifecycle.

## Non-goals

- Deleting polls or any related records.
- Reopening a closed poll or resetting it to draft.
- Moving archived data to another database or cold storage.
- Revoking or deleting access grants when a poll is archived.
- Unpublishing results or changing public result visibility.
- Anonymizing members, ballots, or selections.
- Implementing configurable retention periods or automatic deletion.
- Archiving draft or open polls.
- Bulk archive and restore actions in the first iteration.

## Terminology and state model

The existing poll lifecycle remains:

```text
draft → open → closed
```

Result publication remains an attribute of a closed poll through
`results_published_at`.

Archival is represented independently:

```text
active administration: archived_at is nil
archived administration: archived_at is set
```

The term **active** in this specification means “shown in normal
administration.” It does not mean the poll has `status: :open`.

This separation prevents invalid lifecycle combinations such as replacing
`closed` with an `archived` status and losing the fact that voting ended.

## Eligibility rules

A poll may be archived only when:

- its lifecycle status is `:closed`; and
- it is not already archived.

Both published and unpublished closed polls may be archived. Some polls are
intentionally completed without publishing results. Archival must not force
publication.

Draft polls must be completed or otherwise handled through a future deletion
workflow. Open polls must be closed before archival so an administrator cannot
hide a poll while voting continues.

An archived poll may be restored only when `archived_at` is present. Restoring
it clears archival metadata but leaves its lifecycle status `:closed`.
Restoration never reopens voting.

## Data model

Add the following nullable attribute to `Polly.Polls.Poll`:

- `archived_at`: `:utc_datetime_usec`, the time the poll was archived.

The initial iteration does not require a separate boolean. The timestamp is
both the state marker and useful historical context.

An `archived_by_id` column is deferred because administrator attribution
belongs in the planned audit trail. If attribution is required before that
feature ships, add a nullable user relationship without making archived poll
history dependent on the continued existence of that user.

The migration adds the nullable column and an index that supports the default
and archived list filters. Existing polls receive `archived_at: nil` and remain
visible after deployment.

No related table is changed. In particular, archival does not modify or
duplicate:

- options;
- eligibility records;
- access grants;
- ballots;
- selections; or
- lifecycle and publication timestamps.

Poll slugs remain reserved while archived. Archiving must not make a slug
available for another poll because public URLs and historical references must
continue to identify the original record.

## Poll actions

Add explicit Ash update actions conceptually equivalent to:

```elixir
update :archive do
  accept []
  validate attribute_equals(:status, :closed)
  validate attribute_equals(:archived_at, nil)
  change set_attribute(:archived_at, &DateTime.utc_now/0)
end

update :restore do
  accept []
  validate attribute_does_not_equal(:archived_at, nil)
  change set_attribute(:archived_at, nil)
end
```

The exact non-nil validation may use a custom validation if needed. Both
actions require an authenticated administrator actor under the existing poll
policy.

The actions must not accept `archived_at`, `status`, or lifecycle timestamps
from browser parameters. Server-side changes own those values.

Expected action failures are presented as user-facing validation errors rather
than crashes. Concurrent archive or restore requests must leave the poll in one
valid state; a stale second request may return an “already archived” or
“already restored” result.

## Administrator workflow

### Default poll list

`/admin/polls` shows polls where `archived_at` is `nil`, sorted by the existing
administrative order.

The page adds an **Archived** filter or tab with the archived count. The normal
view should be labelled **Current** or **All current** so administrators can
understand that historical polls have not been deleted.

Suggested filter URLs:

```text
/admin/polls
/admin/polls?view=archived
```

Use LiveView patches for switching filters. Each filter refetches and resets
the poll stream; streams must not be filtered in memory.

The current-polls empty state says “No current polls” and links to the archived
view when archived polls exist. The archived empty state says “No archived
polls.”

### Archive action

Closed, unarchived poll cards and the poll results page offer an **Archive
poll** action. Draft and open polls do not show the action.

Because archival changes normal visibility, confirmation is required. The
confirmation states:

> Archive “Poll title”? It will leave the current poll list, but its
> configuration, ballots, and results will be retained.

Confirming calls the Poll archive action, removes the poll from the current
stream, updates the archived count, and shows:

> “Poll title” archived.

The interface must not use destructive language such as “delete” or imply that
records will be removed.

### Archived poll list

The archived view displays:

- poll title;
- closed status;
- archive date;
- closed date when available;
- whether results are published;
- actions to view results, duplicate, and restore.

Archived polls should be sorted by `archived_at` descending so recently
archived items are easiest to recover.

### Restore action

An archived poll offers **Restore to current polls**. Confirmation is optional
because the action is reversible and does not change lifecycle or public
behavior.

After restoration, the poll disappears from the archived stream, returns to
the normal poll list as a closed poll, and shows:

> “Poll title” restored to current polls.

### Direct administrative access

Archiving hides a poll from the default list; it does not make the poll
unreadable. Existing authorized detail URLs continue to work so bookmarks,
audit references, and support workflows remain useful.

Archived detail pages display an **Archived** notice and avoid suggesting the
poll can be reopened or edited. Existing closed-poll restrictions continue to
apply.

An archived poll may still be duplicated. Duplication is configuration reuse
and already creates a separate draft with no historical ballots or results.

For a closed archived poll whose results have not been published, an
administrator may still visit the results page and publish them. Publishing
results does not automatically restore the poll.

## Public behavior

Archival is invisible to public voter and results routes.

- A closed, unpublished archived poll continues to show that results are not
  yet available.
- A closed, published archived poll continues to show its published results.
- Existing access tokens retain their current validity and revocation state.
- No voter can submit a ballot because the poll remains closed.

Public queries must continue to derive behavior from poll lifecycle and
`results_published_at`, not `archived_at`.

## Query design

Administrative list queries must explicitly choose an archive scope rather
than relying on every caller to remember a raw filter.

Prefer named read actions or a small query boundary conceptually equivalent
to:

```elixir
Poll
|> Ash.Query.filter(is_nil(archived_at))
|> Ash.Query.sort(updated_at: :desc)

Poll
|> Ash.Query.filter(not is_nil(archived_at))
|> Ash.Query.sort(archived_at: :desc)
```

The normal `:read` action should continue to permit loading a poll by ID,
including archived polls. Making the default resource read silently exclude
archived records would break direct history access, relationships, result
queries, and duplication.

Any future poll picker should decide explicitly whether archived polls are
appropriate. Configuration workflows normally exclude them; historical and
reporting workflows normally include them.

## Authorization and security

- Archive and restore routes belong to the authenticated administrator LiveView
  session.
- Domain actions require the current administrator actor.
- Browser parameters contain only the poll identifier and confirmation event;
  they never set archival timestamps directly.
- Public voting routes expose no archive or restore operation.
- Archived records remain subject to the same read authorization as other
  administrative poll records.

The current application treats every authenticated application user as an
administrator. Future role-based authorization must apply the same
poll-management permission to archive and restore actions.

## Audit trail integration

When the administrator audit trail is implemented, successful transitions
produce:

```text
poll.archived
poll.restored
```

Each event targets the poll and stores the poll title snapshot, actor, and
event time. It must not copy ballots, member data, or access tokens into audit
metadata.

Audit creation should occur in the same transaction as the archival change.
Failed or stale requests do not create events.

## Accessibility and responsive behavior

- Current and archived filters use links or tabs with clear selected state and
  keyboard focus indicators.
- Archive confirmation receives focus when opened and returns focus to a
  logical control when cancelled.
- Success and error messages are announced through the existing flash region.
- Archived state is communicated with text, not color alone.
- Archive and restore buttons have poll-specific accessible labels.
- The archived list remains usable at the same responsive breakpoints as the
  current poll list.

## Failure states

The interface distinguishes:

- a draft poll that cannot be archived;
- an open poll that must be closed first;
- a poll already archived by another request;
- a poll already restored by another request;
- a poll that no longer exists or is not readable by the actor; and
- an unexpected persistence failure.

On failure, the list is refetched so stale archive state is corrected. No
failure may alter related poll history.

## Testing requirements

### Resource and domain tests

- archives a closed poll and sets `archived_at`;
- rejects archiving a draft poll;
- rejects archiving an open poll;
- rejects archiving an already archived poll;
- restores an archived poll by clearing `archived_at`;
- rejects restoring a non-archived poll;
- restoration retains `status: :closed` and all lifecycle timestamps;
- archival retains options, eligibility, grants, ballots, and selections;
- archival retains result publication state;
- anonymous callers cannot archive or restore; and
- concurrent or repeated requests leave one valid final state.

### Query tests

- current list queries exclude archived polls;
- archived list queries include only archived polls;
- direct reads by ID still return archived polls;
- archived ordering uses newest `archived_at` first; and
- an archived poll retains its unique slug reservation.

### LiveView tests

- signed-out visitors cannot invoke administrative archive operations;
- closed poll cards expose the archive action;
- draft and open poll cards do not expose the archive action;
- confirming archive removes the poll from the current stream;
- cancelling confirmation leaves the poll unchanged;
- the archived filter displays archived polls and the correct count;
- archived rows display archive and publication state;
- restoring removes the poll from the archived stream and returns it to the
  current list;
- archived poll detail and result routes remain accessible;
- archived polls can still be duplicated; and
- flash messages describe archive and restore outcomes.

### Public behavior tests

- a voter URL for an archived closed poll remains closed;
- published results remain visible after archival;
- unpublished results remain unpublished after archival; and
- restoring a poll does not reopen voting.

## Migration and rollout

1. Add the nullable `archived_at` column and supporting index.
2. Deploy resource actions and archive-aware administrative queries.
3. Add the current/archived list controls and confirmation workflow.
4. Verify existing polls remain visible because their archive timestamp is
   `nil`.
5. Add audit events when the audit trail feature is available.

The rollout requires no data backfill. No poll should be automatically
archived in the first release. Administrators explicitly decide which
historical polls leave the current list.

## Acceptance criteria

The feature is complete when an authenticated administrator can archive a
closed poll, see it disappear from the normal poll list, find it in an archived
view, inspect its retained history and published results, duplicate it, and
restore it as a closed poll—without changing any public voting behavior or
deleting any poll-related record.

## Deferred enhancements

- Bulk archive and restore.
- Automatic archival after a configurable closed period.
- Archive filters by date, title, or publication state.
- Retention schedules and administrator reminders.
- Cold-storage export.
- Legal hold and compliance retention controls.
- Permanent deletion with explicit dependency and retention checks.
- Actor attribution before the general audit trail is implemented.
