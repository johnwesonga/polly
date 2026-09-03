# Anonymous Choices with Participation Tracking — Technical Specification

## Status

In progress. Phase 0 establishes the persisted poll privacy contract without
changing ballot submission behavior. Anonymous voting must remain unavailable
in the administrator UI until the storage, submission, and voter-disclosure
phases are complete.

## Summary

Polly will support polls where the system records which eligible members participated but does not associate those members with their ballot choices.

For an anonymous-choice poll:

- eligibility and private access links remain member-specific;
- Polly records that a member submitted a ballot;
- the ballot and its selections contain no member or access-grant reference;
- administrators may view participation and aggregate results separately; and
- the privacy mode cannot change after the poll opens.

This feature provides application-level separation between identity and choices. It is not cryptographic anonymity and does not protect against an operator with database, infrastructure, or detailed timing access attempting correlation.

## Motivation

Some polls require eligibility enforcement and one vote per member while also requiring members to trust that administrators cannot inspect how an individual voted. Polly's current model does not meet that requirement because every `Ballot` stores a `member_id`.

The desired property is:

> Polly knows that a member voted, but the stored ballot does not reveal how that member voted.

This permits turnout reporting and reminders to non-participants without exposing individual choices.

## Goals

- Allow administrators to select identified or anonymous-choice voting while a poll is a draft.
- Make the selected privacy mode immutable once voting opens.
- Continue authenticating voters through member-specific access grants.
- Enforce eligibility and exactly one final submission per member.
- Track member participation independently from ballot contents.
- Store anonymous ballots without a member, participation, access-grant, invitation, or token reference.
- Preserve aggregate results, turnout, result publication, and poll lifecycle behavior.
- Allow reminder and invitation logic to determine whether a member has voted without querying ballot identity.
- Clearly explain the privacy guarantee and its limits to administrators and voters.
- Preserve identified-poll behavior for existing polls.

## Non-goals

- Hiding whether a member participated.
- Allowing ineligible or unauthenticated voting.
- Cryptographic ballot secrecy, blind signatures, mix networks, or zero-knowledge proofs.
- Protecting against a database or infrastructure operator performing timing analysis.
- Concealing the electorate from administrators.
- Anonymous public polls without private access grants.
- Allowing an administrator to convert an opened or completed poll between privacy modes.
- Recovering or displaying an individual member's anonymous selection.
- Proving to a voter how they voted after submission.

## Privacy terminology

### Identified poll

A ballot stores the submitting member's identity. Existing Polly polls behave this way.

### Anonymous-choice poll

Participation stores the member's identity, while the ballot stores only the poll and selections. No database relationship connects the two records.

### Participation

A poll-scoped record that a member completed a valid submission. It contains no option, selection, ballot, or access-grant identifier.

### Ballot

The immutable submitted choices. In anonymous mode it contains no member-identifying relationship.

## Privacy guarantee

For an anonymous-choice poll, normal Polly application queries and administration screens must be unable to answer:

- Which option did a named member select?
- Which member submitted a particular ballot?
- Which access grant produced a particular ballot?

Polly may answer:

- Is this member eligible?
- Has this member participated?
- How many members participated?
- What are the aggregate option totals?

The application must not add a hidden linkage through IDs, metadata, audit events, job arguments, logs, telemetry, exports, or timestamps intended for correlation.

## Threat model and limitations

The first iteration protects against ordinary administrators using Polly's application interfaces and against accidental association in the primary application schema.

It does not protect against:

- a privileged database administrator observing transactions or write order;
- infrastructure-level request and database timing correlation;
- application code modified to record tokens or selections;
- browser malware, endpoint compromise, or screenshots;
- a voter voluntarily revealing their selection; or
- very small electorates or result sets where choices can be inferred.

Because participation and ballot creation must commit atomically, a sufficiently privileged operator may correlate their creation time. User-facing language must say “anonymous choices” rather than “completely anonymous” or “cryptographically anonymous.”

## User stories

### Administrator

As an administrator, I can choose anonymous choices while configuring a draft poll.

As an administrator, I see a clear explanation that I can track participation but cannot inspect individual choices.

As an administrator, I cannot change the privacy mode after opening the poll.

As an administrator, I can see turnout and a list of participants without seeing their selections.

As an administrator, I can send invitations or reminders only to members who have not participated.

### Voter

As a voter, I am told before submitting whether my choices are identified or anonymous.

As a voter in an anonymous-choice poll, I can verify that my participation was recorded without receiving a receipt that proves my choice.

As a voter, I cannot submit twice using the same or a reissued access grant.

## Poll configuration

Add a poll privacy mode, preferably an Ash enum:

```elixir
defmodule Polly.Polls.Poll.PrivacyMode do
  use Ash.Type.Enum, values: [:identified, :anonymous]
end
```

Add the attribute to `Polly.Polls.Poll`:

```elixir
attribute :privacy_mode, Polly.Polls.Poll.PrivacyMode do
  allow_nil? false
  public? true
  default :identified
end
```

### Lifecycle rules

- `create_draft` accepts `privacy_mode`.
- `update_draft` accepts `privacy_mode` only while the poll is a draft.
- Existing draft validation continues to prevent edits after opening.
- `open` persists the final privacy mode as part of the poll's immutable voting contract.
- Duplication copies the source poll's privacy mode into the new draft, where it may still be changed.
- Existing polls are migrated to `identified`.

## Proposed data model

### Participation resource

Add `Polly.Polls.Participation`, backed by `poll_participations`.

| Attribute | Type | Notes |
| --- | --- | --- |
| `id` | UUID | Primary key |
| `poll_id` | UUID | Required poll relationship |
| `member_id` | UUID | Required member relationship |
| `participated_at` | UTC datetime | Submission completion time |

Required identity:

```elixir
identity :unique_poll_member, [:poll_id, :member_id]
```

The participation resource must not contain:

- `ballot_id`;
- `selection_id`;
- `option_id`;
- `access_grant_id`;
- access tokens;
- invitation-delivery IDs; or
- an operation ID shared with a ballot.

Participation becomes the authoritative source for “has voted” checks in both privacy modes.

### Ballot changes

Change `Ballot.member_id` to allow `nil` and add a privacy snapshot:

| Attribute | Type | Notes |
| --- | --- | --- |
| `privacy_mode` | enum | Required snapshot of the poll mode at submission |
| `member_id` | UUID, nullable | Required for identified ballots; forbidden for anonymous ballots |

Enforce these invariants in the resource and database where practical:

```text
privacy_mode = identified  → member_id IS NOT NULL
privacy_mode = anonymous   → member_id IS NULL
```

The existing unique identity on `[:poll_id, :member_id]` remains a secondary safeguard for identified ballots. SQLite permits multiple `NULL` values in a unique index, so anonymous duplicate prevention must come from the participation identity.

### Relationships

```text
Poll ──< Eligibility >── Member
Poll ──< Participation >── Member
Poll ──< AccessGrant >── Member

Poll ──< Ballot ──< Selection >── Option
```

There is deliberately no relationship between `Participation` and `Ballot`.

## Submission flow

`Polly.Polls.Ballots.submit/3` remains the only ballot-submission boundary.

### Common validation

Inside one database transaction:

1. Resolve the active, unexpired, poll-scoped access grant.
2. Load the poll and require `status == :open`.
3. Derive the member only from the grant.
4. Verify that the member remains in the poll's eligibility snapshot.
5. Verify that every selected option is active and belongs to the poll.
6. Verify that no participation exists for the poll and member.

### Identified branch

1. Create `Participation` for the poll and member.
2. Create a ballot with `privacy_mode: :identified` and `member_id` set.
3. Create the selection records.
4. Commit all records together.

### Anonymous branch

1. Create `Participation` for the poll and member.
2. Create a ballot with `privacy_mode: :anonymous` and `member_id: nil`.
3. Create the selection records.
4. Commit all records together.

No value copied from the grant or participation may be placed on the anonymous ballot or selections.

### Atomicity and concurrency

Participation, ballot, and selections must be created in the same transaction. If any insert fails, the entire submission rolls back.

The unique `poll_id + member_id` participation constraint is the final concurrency guard. If two requests using the same member's credential race:

- only one participation record commits;
- only its ballot and selections commit; and
- the other request returns `:already_submitted`.

Reissuing a member's access grant does not permit another vote because duplicate detection is member- and poll-scoped, not grant-scoped.

## Migration and existing data

The migration must:

1. Add `privacy_mode` to polls with a default of `identified`.
2. Add `privacy_mode` to ballots and backfill it to `identified`.
3. Make `ballots.member_id` nullable.
4. Add the ballot privacy/member consistency constraint where supported.
5. Create `poll_participations` with its unique poll/member index.
6. Backfill one participation for every existing ballot using its poll and member.
7. Verify that existing ballot rows have non-null members before completing the backfill.

The migration must fail rather than silently discard or anonymize inconsistent historical data.

After migration:

- all historical polls remain identified;
- all historical ballots remain linked to their members; and
- participation queries work uniformly for historical and new polls.

## Access-grant behavior

Access grants remain member-specific because Polly still needs to enforce eligibility and record participation.

The grant must not be marked with a ballot ID or selection data. A separate `used_at` field is unnecessary when `Participation` is authoritative.

After participation:

- the grant may still resolve so the member can see the submitted state and later published results;
- another submission is rejected through the participation identity; and
- revoking or reissuing the grant does not alter the recorded participation or ballot.

## Invitation and reminder integration

`Polly.Polls.Invitations` and `InvitationWorker` currently use ballots to determine whether a member has voted. Replace those checks with `Participation` queries.

This supports both privacy modes without loading ballot identity.

Invitation-delivery records must not be associated with ballots. Reminder selection may query:

```text
eligible members MINUS participating members
```

It must never join invitation delivery, access grants, or members to anonymous ballots.

## Turnout and results

### Turnout

Turnout should use:

- numerator: participation count;
- denominator: eligibility count.

The ballot count should equal the participation count after every successful transaction. A discrepancy is an integrity error that should be observable but must not be repaired by attempting to pair individual anonymous records.

### Results

Aggregate result calculation continues to count selections grouped by option. It does not require member identity and therefore needs minimal change.

Results code must not load `ballot.member` for anonymous polls. Exports and administration screens must contain aggregate option totals only unless explicitly producing a separate participation report.

### Participation report

A separate administration view may list:

- eligible member name;
- email;
- participated/not participated; and
- participation time, if the product decides the timestamp is necessary.

It must not include ballot IDs, option labels, or selection counts per member.

## Voter experience

### Before submission

For an anonymous-choice poll, replace the current identified wording with:

> This private link verifies your eligibility. Polly records that you participated, but your choices are stored without your identity.

The review screen should display an **Anonymous choices** indicator and repeat that the final submission cannot be edited.

### Confirmation

After anonymous submission:

- display that participation was recorded;
- display the poll title and submission time;
- do not label the receipt “Voted as”; and
- do not persist or redisplay the selected option after the submission response.

Avoid issuing a durable receipt containing the selected option. Such a receipt could undermine ballot secrecy through coercion or vote selling, even though it does not identify the member in Polly's database.

The LiveView should clear `selected_option`, `selected_option_id`, and sensitive form state after a successful anonymous submission.

### Already submitted

When the member returns through the same or a reissued link, Polly may show:

> Your participation has already been recorded. Anonymous choices cannot be retrieved or changed.

Polly must not attempt to locate or display that member's ballot.

## Administrator experience

### Poll form

Add a required privacy control with two choices:

- **Identified choices** — participation and choices can be associated with members.
- **Anonymous choices** — participation is tracked, but ballots are stored without member identity.

Anonymous mode should include a prominent explanation and a link to its limitations.

### Poll index and detail pages

Display a privacy badge so administrators do not mistake an anonymous poll for an identified one.

### Opening confirmation

Opening an anonymous poll requires confirmation:

> Once voting opens, the privacy mode cannot be changed. Polly will not be able to associate submitted choices with members.

### Administration restrictions

For anonymous-choice polls, the application must not provide:

- per-member ballot detail;
- member-to-option filtering;
- individual-choice exports;
- links from participation rows to ballots; or
- audit events containing selections.

## Poll duplication

Poll duplication copies `privacy_mode` as a poll-detail attribute. Because the duplicate is a draft, the administrator may change it before opening.

No participation or ballot records are ever duplicated.

## Audit trail

Audit these administrator actions:

- poll creation with the chosen privacy mode, if poll-create metadata is expanded;
- privacy-mode changes while in draft; and
- poll opening, whose target poll already preserves the final mode.

The existing `poll.updated` event may include `privacy_mode` in `changed_fields`.

Do not create member-scoped audit events for ballot submission. Audit metadata must never contain:

- ballot IDs;
- participation IDs;
- access-grant IDs used for submission;
- option or selection IDs;
- selected labels;
- private tokens; or
- a value intended to correlate participation and ballot records.

Operational submission metrics must be aggregate and sanitized.

## Authorization and query boundaries

- Public submission continues to operate only through a resolved access grant.
- Direct create actions for ballots, selections, and participations must not be exposed to public callers.
- Administrative participation reads require authentication and poll-management authorization.
- Anonymous ballots must not expose a member relationship because none exists on the record.
- Internal queries should prefer `Participation` for submission status and `Ballot`/`Selection` for results.

Code review should reject any query that joins anonymous ballot data to member, grant, invitation, request, or audit data.

## Logging, telemetry, and error handling

Submission logs and telemetry must not contain:

- tokens;
- member IDs together with ballot or selection IDs;
- option IDs together with member IDs;
- serialized changesets containing both participation and selections; or
- full request parameters.

Safe telemetry may include:

- poll ID;
- privacy mode;
- success/error status;
- duration; and
- a normalized error such as `already_submitted`.

Exceptions raised inside the transaction must rely on Ash's sensitive-value redaction and must not inspect the complete transaction state into logs.

## Implementation phases

### Phase 0 — Poll privacy contract

Implemented.

- Add the `PrivacyMode` enum and default existing behavior to `:identified`.
- Persist privacy mode on polls and accept changes only through draft actions.
- Copy privacy mode when duplicating a poll.
- Migrate existing polls to identified mode and cover lifecycle invariants.
- Reject opening anonymous drafts until anonymous submission is implemented.

This phase deliberately does not expose anonymous mode in the UI or change how
ballots are stored.

### Phase 1 — Participation storage and historical backfill

- Replace the current query-only participation module with an Ash resource.
- Create the poll participation table and unique poll/member identity.
- Backfill participation for existing identified ballots.
- Switch invitation, reminder, and turnout reads to participation records.

### Phase 2 — Privacy-aware ballot schema

- Snapshot privacy mode on every ballot.
- Make ballot member identity nullable and enforce mode/member consistency.
- Preserve identified behavior while anonymous submission remains disabled.
- Add migration and schema-invariant coverage.

### Phase 3 — Atomic anonymous submission

- Create participation, ballot, and selections in one transaction.
- Branch ballot creation by the poll's immutable privacy mode.
- Use participation uniqueness for duplicate and concurrent submission safety.
- Add rollback, reissued-grant, and privacy regression tests.

### Phase 4 — Voter privacy experience

- Add mode-aware disclosure before review and submission.
- Remove identity and selected choices from anonymous confirmation receipts.
- Handle returning anonymous participants without locating their ballot.
- Clear anonymous choice state immediately after successful submission.

### Phase 5 — Administrator configuration and presentation

- Add the privacy selector and explanatory copy to the draft poll form.
- Add privacy badges and an explicit anonymous-mode opening confirmation.
- Keep results and exports aggregate-only for anonymous polls.
- Add authorization, audit, and administrator privacy regression coverage.

### Phase 6 — Integrity monitoring and release gate

- Detect participation/ballot count discrepancies at aggregate level.
- Complete end-to-end migration and privacy tests.
- Review application logs and rendered HTML for correlation leaks.
- Enable anonymous-choice creation only after every release-gate check passes.

## Testing strategy

### Poll configuration tests

- New polls default to identified mode.
- Draft polls accept either privacy mode.
- Draft updates may change privacy mode.
- Open and closed polls reject privacy-mode changes.
- Duplication copies the privacy mode into an editable draft.

### Migration tests

- Existing polls and ballots become identified.
- Existing ballots produce matching participation records.
- Backfill preserves ballot selections and results.
- The unique participation identity is present.
- Anonymous ballots can have `member_id: nil`.
- Identified ballots cannot have `member_id: nil`.
- Anonymous ballots cannot have a member ID.

### Submission tests

- Identified submission creates participation, identified ballot, and selections atomically.
- Anonymous submission creates participation and a ballot with no member ID.
- Anonymous ballot and selection records contain no participation, member, grant, or token reference.
- Invalid grants, ineligible members, closed polls, and foreign options create no participation or ballot.
- A failed selection insert rolls back participation and ballot.
- Concurrent submissions produce one participation and one ballot.
- A reissued grant cannot submit after participation is recorded.
- Returning through a valid grant reports already submitted without locating an anonymous ballot.

### Privacy regression tests

- No application query used by anonymous administration loads ballot members.
- Participation serialization contains no ballot or option data.
- Anonymous ballot serialization contains no member, grant, or participation data.
- Audit metadata contains no submission linkage.
- Captured logs contain neither tokens nor member-to-choice pairs.
- Anonymous confirmation clears selected-option assigns.
- Anonymous confirmation does not render the selected option.

### Results and participation tests

- Aggregate results are identical for equivalent identified and anonymous submissions.
- Turnout uses participation count.
- Invitation readiness treats participating members as already voted.
- Reminder recipient selection excludes participating members.
- Published results expose aggregates only.

### LiveView tests

- Poll form explains and accepts privacy mode.
- Opening an anonymous poll requires explicit confirmation.
- Anonymous voting page displays the privacy explanation.
- Identified voting page retains its current identity wording.
- Anonymous receipt omits member identity and choice.
- Returning voters see the correct anonymous already-submitted message.
- Poll administration displays the privacy badge.

## Integrity monitoring

Track aggregate discrepancies by poll:

```text
participation_count != ballot_count
```

Under the atomic submission design, the counts should always match. Alert on discrepancies, but do not automatically correlate or pair anonymous participation and ballot records during repair.

Any repair tool must operate on aggregate counts or require a documented privacy review.

## Rollout plan

1. Add privacy mode and participation resources.
2. Migrate existing polls and backfill historical participation.
3. Refactor submission status checks to use participation.
4. Add separate identified and anonymous ballot creation actions.
5. Update invitation delivery and result turnout queries.
6. Add poll configuration and privacy disclosures.
7. Update voter review, confirmation, and returning-voter states.
8. Add administration privacy badges and participation reporting boundaries.
9. Run privacy regression tests and inspect logs in development.
10. Enable anonymous-choice poll creation.

The feature should not be exposed until the migration, transactional submission, UI disclosures, and privacy regression tests ship together.

## Acceptance criteria

- An administrator can select anonymous choices for a draft poll.
- Privacy mode cannot change after the poll opens.
- A valid eligible member can submit exactly once.
- Submission records the member's participation.
- The anonymous ballot has `member_id: nil` and no grant or participation relationship.
- Selections relate only to the anonymous ballot and selected options.
- A normal administrator cannot associate an anonymous ballot with a participant through Polly's UI or domain APIs.
- Turnout, invitations, and reminders use participation rather than ballot identity.
- Aggregate results work for both privacy modes.
- Anonymous voter confirmation reveals neither the member identity nor selected choice in its receipt.
- Existing polls retain identified behavior.
- Audit events, logs, telemetry, and jobs do not create a member-to-choice linkage.
- The UI describes the feature as anonymous choices with participation tracking and does not promise cryptographic anonymity.

## Likely follow-up work

- Configurable suppression or coarsening of participation timestamps.
- Minimum electorate or response thresholds before publishing results.
- Small-group inference warnings.
- Formal privacy review and structured threat modeling.
- Retention policies that anonymize identified historical ballots.
- Cryptographically unlinkable eligibility credentials for stronger anonymity.
- Independent verification or externally auditable election protocols.

## Open decisions before implementation

1. Should administrators see exact participation timestamps, date-only values, or only participated/not participated?
2. Should anonymous results require a minimum number of ballots before publication?
3. Should the voter confirmation display the selected choice transiently, or omit it immediately after submission as recommended here?
4. Should identified polls also use `Participation` as the sole turnout source, as this specification recommends?
5. What wording will legal, governance, or election owners approve for the privacy disclosure?
