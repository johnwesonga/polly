# Poll duplication feature specification

## Summary

Allow an authenticated administrator to create a new draft poll from an
existing poll. This reduces repeated setup while preserving the rule that each
poll has an independent lifecycle, electorate, access credentials, ballots,
and results.

The feature is deliberately split into two iterations:

1. **Details-only duplication** copies basic poll configuration into a new
   draft.
2. **Configuration duplication** optionally copies options and the electorate
   into the new draft.

The operation is called **Duplicate poll** in the interface. “Clone” may be
used informally, but the product copy should consistently use “duplicate.”

Implementation status: iteration 1 is complete. Iteration 2 remains planned.

## Complexity assessment

This is not overly complex if delivered in the proposed iterations.

- Iteration 1 is **small**. It creates one new `Poll` from a controlled subset
  of attributes and relies on existing draft creation rules.
- Iteration 2 is **medium**. It creates several related records atomically and
  must define how inactive members, access grants, concurrent edits, and
  partial failures are handled.

The feature becomes high-risk only if “duplicate” is allowed to copy lifecycle
state, access tokens, ballots, or historical results. Those records must remain
outside the feature in every iteration.

## Goals

- Let administrators reuse common poll wording without re-entering it.
- Later, let administrators reuse common options and electorate membership.
- Always produce an independently editable draft poll.
- Make it unmistakable which configuration was copied and which historical
  data was not.
- Keep the duplicate operation atomic and safe to retry.

## Non-goals

- Reopening or resetting a closed poll.
- Creating a live alias of a source poll.
- Keeping the source and duplicate synchronized after creation.
- Copying status, lifecycle timestamps, publication state, access tokens,
  ballots, selections, turnout, or results.
- Combining data from multiple source polls.
- Scheduling the duplicate to open automatically.
- Copying email delivery history or external distribution state.

## Core invariants

Every duplicate:

- receives a new poll ID;
- starts with `status: :draft`;
- has `opened_at`, `closed_at`, and `results_published_at` set to `nil`;
- receives a new unique slug;
- remains independent from future source-poll changes; and
- contains no ballots, selections, or historical result state.

Duplicating a poll is configuration reuse, not historical-data duplication.

## Eligible source polls

An administrator may duplicate a draft, open, or closed poll. The source is
read as it exists when the operation starts, but its lifecycle state is never
copied.

Allowing any source status is useful because completed polls are often the best
templates for recurring votes. The source poll remains unchanged.

## Iteration 1 — details only

### Copied fields

- `title`, transformed into a copy title;
- `description`; and
- `selection_mode`.

Although the first release only supports `:single`, explicitly copying
`selection_mode` makes the behavior clear and prepares for future modes.

### Excluded relationships and fields

- options;
- eligibility records;
- access grants and tokens;
- ballots and selections;
- lifecycle status and timestamps;
- result publication state; and
- creation/update timestamps.

### Default title

The generated title is:

```text
Copy of <source title>
```

If that exceeds the 160-character poll title limit, the source portion is
truncated before adding the prefix. The administrator can edit the title on
the normal draft form immediately after duplication.

### Slug generation

The new slug is based on the source slug:

```text
<source-slug>-copy
<source-slug>-copy-2
<source-slug>-copy-3
```

Slug generation must respect the 180-character limit. The base is truncated as
needed before adding the suffix. The database unique identity remains the final
concurrency guard. If another request claims the same slug, the operation
retries with the next suffix rather than exposing a uniqueness error to the
administrator.

### Administrator workflow

1. The poll list and poll results page offer a **Duplicate poll** action.
2. A confirmation explains that only title, description, and selection mode
   will be copied.
3. Confirmation creates the draft.
4. The administrator is redirected to the new poll's edit page with a message:
   “Draft duplicated from `<source title>`.”
5. The new poll can then follow the existing details, options, electorate,
   access, open, close, and publish workflow.

The new poll must not be created until the administrator confirms the action.

## Iteration 2 — options and electorate

Iteration 2 changes duplication into a short configuration form. The
administrator chooses what to copy:

- **Poll details** — always selected and cannot be disabled.
- **Options** — optional.
- **Electorate** — optional.

The defaults should select options and leave electorate unselected. Options are
typically reusable configuration; electorate membership is more sensitive to
roster changes and deserves explicit confirmation.

### Copying options

When selected:

- copy active options only;
- preserve each option's label and position;
- create new option IDs belonging to the duplicate poll; and
- leave the copied options editable because the duplicate is a draft.

Inactive options are omitted and reported in the confirmation summary. No
option relationship points back to the source poll.

If the source has no active options, duplication still succeeds and reports
that zero options were copied.

### Copying the electorate

When selected:

- copy eligibility only for members who are active when duplication runs;
- create new eligibility IDs belonging to the duplicate poll;
- skip inactive or missing members and report the skipped count; and
- issue a fresh access grant and fresh token for every copied eligible member.

Source access grants are never copied, even if they are still valid. Revocation
and expiration state are also never copied. New grants should use the normal
default expiration behavior.

Copying eligibility creates a new draft snapshot. Subsequent changes to either
poll's electorate remain independent.

### Iteration 2 preview

Before confirmation, show:

- source poll title and status;
- proposed duplicate title and slug;
- number of active options that will be copied;
- number of active eligible members that will be copied;
- number of inactive members that will be skipped; and
- a permanent warning that ballots, results, and existing access links will
  not be copied.

## Domain design

Duplication must be owned by a domain service rather than assembled in
LiveView event handlers. The API should be conceptually equivalent to:

```elixir
Polly.Polls.Duplicator.duplicate(source_poll, options, actor)
```

Iteration 1 options:

```elixir
%{copy_options?: false, copy_electorate?: false}
```

Iteration 2 may enable either flag. The service returns the new poll and a
summary:

```elixir
{:ok,
 %{
   poll: duplicated_poll,
   options_copied: 4,
   members_copied: 18,
   members_skipped: 2
 }}
```

The service must:

1. require an authenticated administrator actor;
2. reload the source and requested relationships inside the operation;
3. copy only explicitly allowlisted attributes;
4. generate a unique title and slug without accepting lifecycle fields from
   browser parameters;
5. create the poll and requested relationships in one repository transaction;
6. roll back every new record if any create fails; and
7. return actionable errors without changing the source.

The LiveView supplies only the source poll ID and copy choices. It must not
supply copied member IDs, option IDs, status, timestamps, or access tokens.

## Authorization

- The duplicate action is available only in the authenticated administrator
  LiveView session.
- The domain operation requires an administrator actor and uses existing
  resource actions wherever possible.
- Anonymous callers and public access-grant holders cannot duplicate polls.
- The source poll must be readable by the actor at execution time.

The first release treats every application user as an administrator, matching
the existing product decision. Future role-based administration must apply the
same poll-management permission to duplication.

## Transaction and concurrency behavior

The duplicate poll and all optionally copied relationships are created in one
transaction. A failure leaves no partial draft, orphan option, eligibility, or
access grant.

Likely races include:

- two administrators duplicating the same poll and choosing the same slug;
- a member being deactivated while an electorate is copied;
- source draft options or eligibility changing during duplication; and
- a relationship failing after the new poll has been created.

The transaction and database identities are the final safeguards. The service
should use a consistent source snapshot for its reads, retry bounded slug
collisions, skip members that are no longer active at creation time, and roll
back on any non-recoverable relationship error.

## Audit and observability

Log one structured completion event containing:

- source poll ID;
- duplicate poll ID;
- administrator ID;
- copied option count;
- copied electorate count; and
- skipped electorate count.

Do not log access tokens or member contact details. A durable audit-history UI
is deferred to hardening unless broader administrator accountability requires
it sooner.

## Accessibility and responsive behavior

- The duplicate action has an unambiguous accessible name containing the poll
  title when presented in a list.
- Confirmation identifies the source and clearly states that a new draft will
  be created.
- Iteration 2 checkboxes use the shared input component and have explanatory
  labels.
- Status and completion messages are announced through the existing flash
  region.
- The preview summary remains readable without color and on narrow screens.
- Focus moves to the new poll edit page after successful duplication.

## Failure states

The interface distinguishes:

- source poll no longer exists or is not readable;
- source configuration changed before confirmation;
- no active options to copy;
- inactive electorate members skipped;
- slug collision retries exhausted;
- relationship validation failure; and
- unexpected transactional failure.

A zero-option or zero-member copy is a successful duplication with a warning,
not a partial failure. The administrator can configure the new draft normally.

## Testing requirements

### Iteration 1 domain tests

- duplicates details from draft, open, and closed polls;
- always creates a distinct draft with cleared lifecycle timestamps;
- copies description and selection mode;
- generates a unique title and slug within field limits;
- handles repeated and concurrent duplication without slug collisions;
- copies no options, eligibility, grants, ballots, or selections;
- leaves the source unchanged when duplication succeeds; and
- rolls back and returns an error when poll creation fails.

### Iteration 1 LiveView tests

- signed-out visitors cannot invoke duplication;
- the poll list exposes a uniquely identified duplicate action;
- confirmation explains that only details are copied;
- successful duplication redirects to the new draft edit page;
- the new page displays a success message naming the source; and
- the source poll remains accessible and unchanged.

### Iteration 2 domain tests

- copies active options with labels and positions when selected;
- omits all options when not selected;
- copies active eligible members when selected;
- skips inactive eligible members and reports the count;
- issues fresh, unique access grants for copied members;
- never copies revoked, expired, or active source tokens;
- never copies ballots, selections, or result state;
- creates independent relationship records with new IDs;
- rolls back the complete duplicate when a related create fails; and
- produces a consistent result during concurrent source changes.

### Iteration 2 LiveView tests

- defaults to copying options but not electorate;
- presents accurate preview counts and skipped-member warnings;
- allows either optional copy choice to be changed;
- renders copied configuration on the new draft pages; and
- never renders or transmits source access tokens.

## Acceptance criteria

### Iteration 1

An authenticated administrator can duplicate any poll and receive a new,
uniquely named draft containing only the source title, description, and
selection mode. The operation copies no relationships or history and redirects
to the normal draft editor.

### Iteration 2

An authenticated administrator can preview and optionally copy active options
and active electorate members in one atomic operation. Copied members receive
fresh access grants, skipped members are reported, and ballots, results, and
source credentials are never copied.

## Likely implementation issues

The main issues to plan for are:

1. **Ambiguous expectations.** Administrators may assume “duplicate” includes
   votes or creates a synchronized template. Confirmation copy must define the
   boundary every time.
2. **Slug collisions.** Concurrent duplicates require database-backed retry
   behavior rather than a read-then-create uniqueness assumption.
3. **Title and slug limits.** Copy suffixes must not make otherwise valid
   source values invalid.
4. **Stale electorate membership.** A historical electorate may contain
   inactive members. Iteration 2 must skip and report them.
5. **Credential leakage.** Access tokens cannot be copied, displayed in the
   preview, accepted from the browser, or included in logs.
6. **Partial nested copies.** Options, eligibility, and fresh grants must share
   one transaction with new-poll creation.
7. **Concurrent source edits.** Draft options or electorate can change while a
   preview is open. Confirmation must reload or detect the changed source.
8. **Large electorates.** Copying many eligibility and grant records can make a
   LiveView request slow. Use bounded concurrent preparation where helpful, but
   keep database writes transactional and measure before optimizing.
9. **Future configuration growth.** New poll attributes need an explicit
   product decision before being added to the allowlist; blindly copying the
   entire resource risks leaking lifecycle or operational state.

## Deferred enhancements

- Saving named poll templates independent of historical polls.
- Letting administrators edit the title and slug before duplication.
- Copying schedules, notification settings, or reusable audience groups.
- Choosing individual options or electorate members during duplication.
- A comparison screen between source and duplicate.
- Bulk duplication or recurring poll generation.
