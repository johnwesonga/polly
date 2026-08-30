# Multiple-Choice Polls with Configurable Selection Limits — Technical Specification

## Status

In progress. The data-model foundation now includes poll selection-limit
columns with `1..1` defaults, a ballot-and-option selection identity, and the
`:multiple` selection mode. Limit configuration and multiple-selection
submission remain disabled until later slices.

## Summary

Polly currently supports one selection per ballot. This feature adds multiple-choice polls whose administrators can configure the minimum and maximum number of options each voter may select.

The same model supports:

- **choose up to three** — minimum `1`, maximum `3`;
- **choose exactly three** — minimum `3`, maximum `3`; and
- **choose between two and five** — minimum `2`, maximum `5`.

Existing polls remain single-choice polls with a minimum and maximum of one. Ballots remain final, eligibility and access-grant enforcement remain unchanged, and one member may still submit only one ballot per poll.

This is a medium-complexity domain change. The existing `Ballot` and `Selection` split already supports multiple stored selections, but the selection identity, transactional submission service, public voting UI, poll configuration, results language, duplication behavior, and tests all currently assume exactly one option.

## Goals

- Allow an administrator to choose single- or multiple-choice while a poll is a draft.
- Allow a multiple-choice poll to define inclusive minimum and maximum selection counts.
- Present voters with clear instructions and a live selection count.
- Enforce selection limits authoritatively in the transactional ballot service.
- Store all selections atomically with the ballot.
- Preserve one final ballot per eligible member and poll.
- Count each selected option once per ballot.
- Keep turnout based on submitted ballots rather than total selections.
- Preserve all current access, lifecycle, audit, invitation, and result-publication rules.
- Migrate existing polls without changing their behavior.

## Non-goals

- Ranked-choice voting or ordered selections.
- Weighted selections or distributing a fixed number of points.
- Write-in options.
- Conditional limits per option, member, or electorate group.
- Option groups with separate limits.
- Cumulative voting where the same option may be selected more than once.
- Editing a submitted ballot.
- Quorum, threshold, tie-breaking, or seat-allocation rules.
- Treating the option with the most selections as a legally authoritative winner.

## Terminology

- **Selection mode**: whether a ballot permits one option or multiple options.
- **Minimum selections**: the fewest distinct options required for a valid ballot.
- **Maximum selections**: the most distinct options permitted for a valid ballot.
- **Support rate**: the percentage of submitted ballots that selected an option.
- **Turnout**: the percentage of eligible members who submitted a ballot.

## Product rules

1. `:single` polls require exactly one selection.
2. `:multiple` polls require a configured inclusive range.
3. Minimum and maximum must both be positive integers.
4. Minimum must not exceed maximum.
5. A poll cannot open when its maximum exceeds its number of active options.
6. A poll cannot open when its minimum exceeds its number of active options.
7. Every submitted option must be active and belong to the submitted poll.
8. Duplicate option IDs in one submission are invalid; they are not silently deduplicated.
9. All selections and the ballot commit in one database transaction.
10. A failed validation leaves neither a ballot nor partial selections behind.
11. Selection configuration is editable only while the poll is a draft.
12. Once opened, the mode and limits are frozen along with the options and electorate.
13. A voter still submits at most one final ballot for the poll.

Abstention through an empty ballot is not supported in this iteration. Administrators who need an explicit abstention should add it as a poll option.

## Data model

### Selection mode

Extend `Polly.Polls.Poll.SelectionMode`:

```elixir
defmodule Polly.Polls.Poll.SelectionMode do
  use Ash.Type.Enum, values: [:single, :multiple]
end
```

`selection_mode` remains non-null and defaults to `:single`.

### Poll limits

Add two public, non-null integer attributes to `Polly.Polls.Poll`:

| Attribute | Default | Meaning |
| --- | ---: | --- |
| `minimum_selections` | `1` | Minimum distinct options required |
| `maximum_selections` | `1` | Maximum distinct options allowed |

Naming the columns explicitly is preferable to ambiguous names such as `selection_limit`. The pair describes the complete validity range and avoids adding another field when exact-count polls are introduced.

Resource validation must enforce:

```text
minimum_selections >= 1
maximum_selections >= 1
minimum_selections <= maximum_selections
```

Mode-specific validation must enforce:

```text
single   => minimum_selections == 1 and maximum_selections == 1
multiple => minimum_selections <= maximum_selections
```

The open action must compare both limits with the current active option count. Drafts may temporarily have incomplete option configuration, but they cannot open until valid.

### Selection identity

The current identity permits only one selection per ballot:

```elixir
identity :one_selection_per_ballot, [:ballot_id]
```

Replace it with:

```elixir
identity :unique_option_per_ballot, [:ballot_id, :option_id]
```

This permits multiple distinct options while preventing the same option from being stored twice for one ballot. The database identity is a final integrity constraint and does not replace service-level duplicate validation.

No rank or position belongs on `Selection` for this feature. Ranked-choice voting should introduce ordered-selection semantics separately.

## Migration

Create a migration that:

1. adds `minimum_selections` with a non-null default of `1`;
2. adds `maximum_selections` with a non-null default of `1`;
3. drops the unique identity on `ballot_id` alone; and
4. creates a unique identity on `ballot_id` and `option_id`.

All existing poll rows therefore retain exactly-one behavior without backfill ambiguity. Existing ballots and selections remain valid.

The migration must be reversible. Before rollback, it must detect ballots containing more than one selection and refuse to recreate the old identity rather than deleting data.

## Poll actions and validation

### Draft creation

`create_draft` accepts:

- `selection_mode`;
- `minimum_selections`; and
- `maximum_selections`.

When mode is omitted, all three values retain single-choice defaults.

### Draft update

`update_draft` accepts the selection configuration in addition to title and description. It continues to reject changes after the poll leaves draft status.

Changing the mode to `:single` should set both limits to one in the form before submission. The resource action must still validate the submitted values because the form is not a security boundary.

### Opening a poll

Extend poll-readiness validation to reject:

- inconsistent mode and limit values;
- minimum greater than maximum; and
- either limit greater than the number of active options.

Error messages should be actionable, for example:

```text
Maximum selections cannot exceed the 4 active options.
Single-choice polls must require exactly one selection.
```

## Ballot submission service

### API

Change the authoritative API from a single option ID to a collection:

```elixir
Ballots.submit(poll_id, token, option_ids)
```

`option_ids` is a list of option UUIDs for both modes. A single-choice submission therefore uses a one-element list. Keeping one input shape avoids branching at the caller boundary and makes the service validate the poll's stored configuration.

If a compatibility wrapper is useful during migration, `submit/3` may temporarily wrap a binary option ID in a list, but new callers and tests must use lists. The wrapper should be deprecated and removed once all internal callers are migrated.

### Transaction sequence

Within one `Polly.Repo.transaction/1`, submission must:

1. resolve the access grant from the poll and token;
2. load the poll and require `:open` status;
3. derive the member from the grant;
4. verify the member remains eligible;
5. normalize only the transport representation, not semantic duplicates;
6. require all submitted IDs to be unique;
7. validate the count against the poll's minimum and maximum;
8. load all active options matching both the poll and submitted IDs;
9. verify that the loaded ID set exactly matches the submitted ID set;
10. verify the member has not already submitted a ballot;
11. create the ballot;
12. create one selection per option; and
13. commit before broadcasting the result update.

The service must validate the collection with set comparison rather than running one query per option.

### Errors

Extend `submission_error` with safe domain errors:

```elixir
:too_few_selections
:too_many_selections
:duplicate_options
:option_not_in_poll
```

The public UI may provide precise limit guidance before submission. Errors caused by tampered input should return a generic ballot error without revealing unrelated poll data.

### Concurrency and atomicity

`Ballot` retains its unique identity on `[:poll_id, :member_id]`, protecting against concurrent submissions. Exactly one racing submission may commit. The other must normalize the database identity failure to `:already_submitted`.

The selection inserts must occur inside the same transaction as the ballot insert. `Task`, LiveView processes, and independent create calls outside the transaction are not acceptable.

## Administrator experience

### Poll form

Add a **Selection rules** section to the draft poll form:

- **Single choice** — “Members choose exactly one option.”
- **Multiple choice** — “Members may choose more than one option.”

When multiple choice is selected, show integer inputs for:

- **Minimum choices**; and
- **Maximum choices**.

The form should include quick presets:

- Up to `N`: minimum 1, maximum `N`.
- Exactly `N`: minimum and maximum `N`.

Presets are optional UI conveniences; the persisted model remains the explicit range.

For non-draft polls, display the rules as read-only configuration. Do not offer an edit control.

### Readiness and summaries

Poll list/detail surfaces should summarize the rule using plain language:

- `Choose one`
- `Choose up to 3`
- `Choose exactly 3`
- `Choose 2–5`

The open action should surface selection-rule readiness errors alongside the existing option and electorate checks.

### Duplication

Poll duplication must copy `selection_mode`, `minimum_selections`, and `maximum_selections` in every iteration. A duplicated poll remains a draft, so administrators may change the copied rules before opening it.

Audit metadata for poll creation or update may record mode and numeric limits. It must not include ballot selections or member information.

## Member voting experience

### Selection controls

- Render radio controls for `:single` polls.
- Render checkbox controls for `:multiple` polls.
- Keep each entire option card clickable and keyboard accessible.
- Use the existing Touchpad selected-card treatment for both modes.
- Use stable DOM IDs for the fieldset, controls, counter, validation message, review action, and selected review rows.

Do not implement checkbox behavior with a client-only JavaScript state model. LiveView remains authoritative, and ordinary form submission must carry all selected option IDs.

### Instructions and count

Display mode-specific instructions:

- `Choose one option.`
- `Choose up to 3 options.`
- `Choose exactly 3 options.`
- `Choose between 2 and 5 options.`

For multiple-choice polls, show a live counter such as:

```text
2 of up to 3 selected
```

The review button remains disabled until the minimum is satisfied. Once the maximum is reached, unselected controls should be disabled while selected controls remain available for deselection. Server validation remains mandatory because disabled controls and LiveView events can be bypassed.

### Review and confirmation

The review step lists every selected option in poll option order. It repeats the finality warning and submits the full collection as hidden form inputs.

The submission receipt likewise lists every selection. Existing ballots must load all selections rather than calling `List.first/1`.

If the poll closes or the access grant becomes invalid during review, submission follows the existing closed or invalid-link behavior.

## Results

### Counting

Each selection contributes one count to its option. Because option IDs are unique within a ballot, one ballot cannot increment the same option twice.

Turnout remains:

```text
submitted ballots / eligible members
```

It must never use total selections as the numerator.

For multiple-choice polls, each option's percentage is its support rate:

```text
ballots selecting the option / submitted ballots
```

Percentages may legitimately total more than 100%. The results UI must label them as “selected by” or otherwise explain the denominator. It must not imply that the values form parts of a single 100% vote share.

For single-choice polls, the same calculation remains equivalent to the current vote percentage and totals approximately 100%, subject to rounding.

### Winner language

The highest selection count may be visually highlighted, but multiple-choice results should use **Most selected** rather than **Winner** unless Polly later adds poll-specific outcome rules. Ties should be labelled **Most selected (tie)**.

The result projection should expose enough context for rendering:

```elixir
%{
  selection_mode: :multiple,
  total_selections: 12,
  ballot_count: 5,
  options: [
    %{votes: 4, percentage: 80.0, ...}
  ]
}
```

## Invitations and access

Eligibility, access-grant issuance, revocation, expiration, invitation deduplication, and participation tracking are unchanged.

The invitation email may state the selection rule, but it must not include option labels by default. For example: “You may select up to three options.” The private URL and token handling requirements remain unchanged.

Invitation readiness continues to treat any submitted ballot as `already_voted`, regardless of how many selections it contains.

## Authorization, privacy, and audit

- Only authenticated administrators may configure selection rules.
- Ash actions, not only LiveView fields, enforce draft-only mutation.
- The public submission service trusts the access grant for member identity.
- Audit events may record poll configuration but never selections tied to a member.
- Logs, telemetry, Oban arguments, and invitation metadata must not expose private voting choices.
- This feature does not make ballots anonymous; the separate anonymous-choices specification governs identity separation.

## Testing strategy

### Poll configuration tests

- Existing polls default to single choice with limits `1..1`.
- Draft multiple-choice polls accept valid ranges.
- Single-choice polls reject limits other than `1..1`.
- Minimum zero, maximum zero, and minimum greater than maximum are rejected.
- Opening is rejected when a limit exceeds the active option count.
- Open and closed polls reject selection-rule changes.
- Duplication copies mode and limits.

### Ballot domain tests

- Single-choice submission accepts exactly one option.
- Single-choice submission rejects zero or multiple options.
- Multiple-choice submission accepts the lower and upper bounds.
- Submissions below and above the range are rejected.
- Duplicate option IDs are rejected.
- Inactive, unknown, and cross-poll options are rejected.
- A mixed valid/invalid collection creates no ballot or selections.
- Every valid selection is stored in the same transaction.
- Concurrent submissions still produce one final ballot.
- A failed selection insert rolls back the ballot and preceding selections.

### LiveView tests

- Single-choice polls render radios and current instructions.
- Multiple-choice polls render checkboxes and range-specific instructions.
- Selection count updates on select and deselect.
- Review is disabled below the minimum.
- Unselected options are disabled at the maximum.
- Review displays all choices in option order.
- Going back preserves the current selections.
- Confirmation submits all selected IDs.
- Existing-ballot and receipt states show all selections.
- Tampered parameters receive a safe error.

### Results tests

- Option counts include every stored selection.
- Ballot count and turnout do not increase with additional selections.
- Support rate uses ballot count as the denominator.
- Multiple-choice percentages may exceed 100% in total.
- Zero-ballot results avoid division errors.
- Most-selected and tie summaries use mode-appropriate language.
- Published member results and administrator results use the same projection.

### Migration tests

- Existing polls become `:single` with limits `1..1`.
- Existing selections remain valid.
- Multiple different options can be stored for a new ballot.
- The same option cannot be stored twice for one ballot.

## Rollout plan

1. Add the poll limit attributes and migrate existing rows to `1..1`.
2. Replace the selection identity with the ballot-and-option identity.
3. Extend the enum and add poll configuration validations.
4. Change the submission service to accept and validate option ID lists.
5. Migrate all single-choice callers and tests to the list-shaped API.
6. Update poll creation, editing, summaries, duplication, and audit metadata.
7. Add the multiple-choice voting, review, receipt, and existing-ballot UI.
8. Update result projections and mode-specific result language.
9. Update invitation copy where appropriate.
10. Run the complete single-choice regression suite before enabling multiple choice.

A feature flag is optional because migrated polls preserve their current behavior. If the administrator UI and public voting UI cannot be deployed atomically, hide creation of `:multiple` polls until every read and submission path supports them.

## Acceptance criteria

- Administrators can configure valid multiple-choice ranges on draft polls.
- Existing and newly created single-choice polls continue to require exactly one option.
- A multiple-choice voter can select, review, and atomically submit a valid set of distinct options.
- Invalid counts, duplicate IDs, inactive options, and cross-poll options create no partial records.
- One member can still submit only one final ballot per poll.
- Poll configuration and options remain frozen after opening.
- Results count all selections while turnout counts ballots.
- Multiple-choice percentages are clearly presented as support rates and may total over 100%.
- Poll duplication retains the configured mode and limits.
- Published results, receipts, and existing-ballot states display all selections.
- Authorization, audit, invitation, and private-link protections remain intact.

## Open decisions

1. Should the first UI expose arbitrary minimum/maximum ranges, or begin with only “up to N” and “exactly N” presets?
2. Should selecting the maximum disable remaining options or allow another click to replace a selection?
3. Should invitation emails include the selection rule?
4. Should administrator result exports include one row per ballot, one row per selection, or both formats?
5. Should “Most selected” highlighting be enabled by default for multiple-choice polls or require an explicit outcome setting?

## Related documentation

- [Configurable polls proposal](configurable-polls-proposal.md)
- [Anonymous choices specification](anonymous-choices-spec.md)
- [Poll duplication specification](poll-duplication-spec.md)
- [Email invitation delivery specification](email-invitation-delivery-spec.md)
