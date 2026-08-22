# Configurable polls and nominations proposal

## Executive summary

Nominator can evolve from one hard-coded swimmer award into a reusable polling
application, but the change is a domain redesign rather than an extra field on
the current vote.

The recommended target is a generic, single-choice poll system with:

- polls that own their lifecycle and configuration;
- administrator-defined text options;
- an explicit snapshot of eligible voters for each poll;
- one ballot per eligible voter and one selection per single-choice ballot;
- poll-and-member-specific revocable access links; and
- results and real-time events scoped to a poll.

This directly supports polls such as **2027 Team Theme**, with options such as
“Under the Sea” or “Retro Arcade.” Member-nomination options can be introduced
later without changing ballots, eligibility, or access grants.

Start with single-choice polls. The proposed ballot/selection split leaves a
clean path to multiple-choice or ranked-choice voting without redesigning the
core tables again.

## Direction and approved first-release decisions

The preferred direction is now to build this architecture in a **new Phoenix/Ash
project** and retain Nominator as a standalone proof of concept. This avoids a
large compatibility migration and allows generic terminology, poll-scoped
security, and lifecycle rules to be foundational rather than retrofitted.

The following first-release product decisions have been made:

- **One vote per member per poll.**
- **Submitted ballots are final.** There is no edit or resubmit flow.
- **Results are private while voting is open.**
- **An administrator explicitly publishes results after the poll closes.**
- **Published results are visible to members.**
- **Voting links are not family-specific and are revocable.**
- **Use generic terminology** such as Member rather than Swimmer.
- **Implement one option type initially.** Use administrator-defined text
  options; member-backed nomination options can be added later.
- **Optimize for the simplest complete flow**, then iterate.

### Recommended interpretation of member links

“Not family-specific” should mean one access grant per **member and poll**, not
one shared URL for the entire poll.

A single shared URL cannot reliably enforce one final vote per member unless
members also have authenticated accounts. Asking someone to select their name
from a roster would allow impersonation and could permanently consume another
member's ballot.

For the simplest first release, generate a unique revocable access token for
each eligible member:

```text
/polls/:poll_id/vote/:member_access_token
```

The token identifies the poll and member. The voting page must never accept a
browser-supplied member ID as authority. A valid, unrevoked grant allows that
member to vote while the poll is open and view results after publication.

Member authentication can replace or supplement invitation tokens later. It is
not required for the first release if the individual links are treated as
credentials and distributed privately.

### Simplified first-release workflow

1. An administrator creates a draft poll.
2. The administrator adds two or more text options.
3. The administrator chooses eligible members.
4. The system generates one revocable link per eligible member.
5. The administrator opens the poll and distributes links.
6. Each link permits exactly one final ballot submission.
7. The administrator closes the poll.
8. Results remain hidden until the administrator publishes them.
9. Members with valid links can view the published results.

This flow intentionally excludes member-backed options, write-ins,
multiple-choice voting, ranked voting, scheduling, member accounts, and public
result pages.

## Current-state assessment

The current application models one global election implicitly:

| Current concept | Current implementation | Limitation |
| --- | --- | --- |
| Poll | Hard-coded in LiveView copy | There is no persisted poll identity or configuration. |
| Poll status | Singleton `VotingSettings` row | Status cannot differ between polls. |
| Voter | `Swimmer` | Only swimmers can cast votes. |
| Option | Another `Swimmer` through `candidate_id` | Themes, dates, activities, and arbitrary choices cannot be represented. |
| Ballot | Derived from all swimmers in a family | Eligibility is not stored or scoped to a poll. |
| Access | Global `Family.family_token` | One permanent token grants access to every current/future family ballot. |
| Submission | One `Vote` row | The row combines ballot, voter, poll choice, and submission state. |
| Duplicate protection | Unique `votes.voter_id` | A swimmer can vote only once across the entire application, not once per poll. |
| Results | All votes grouped by swimmer candidate | Results cannot be filtered by poll. |
| Live updates | Global PubSub topics | Events from different polls would interfere. |

Hard-coded assumptions also appear in:

- `/vote/:family_token`;
- `VoteLive` headings, instructions, autocomplete, and form field names;
- `AdminLive` season/title, global status, results, and roster status;
- `Ballots.get_by_family_token/1`;
- `Results.list/0`;
- `Vote` relationships and its `one_vote_per_voter` identity;
- JavaScript names such as `CandidateAutocomplete`; and
- tests, seeds, README content, and email-link plans.

## Remaining decisions before implementation

These choices materially affect the schema and user experience.

### Poll behavior

- Can an administrator reopen a closed poll?
- Can published results be withdrawn, or is publication final?
- Should a poll have a separate archive state after publication?

### Electorate and access

- Does every member participate by default, or must the administrator always
  choose the electorate?
- Does the first release need groups/segments, or only all-members and
  individually selected members?
- How are individual member links delivered initially: copy/paste, CSV export,
  or email?
- Should revoking and reissuing a link invalidate only the token, or also an
  unsubmitted ballot?

### Option types

- Does a text option need a description in addition to its label?
- Does the first release need option ordering by drag-and-drop, or are simple
  move-up/move-down controls sufficient?

The approved first release is: one vote per eligible member, single-choice text
options, no write-ins, manual open/close, final submissions, admin-private
results until explicitly published, member-visible published results,
poll-and-member-specific revocable links, and options frozen once voting opens.

## Recommended domain model

### `Nominator.Polls.Poll`

Represents one independently managed poll.

Suggested attributes:

- `id`: UUID
- `title`: required string
- `description`: optional text
- `slug`: unique, human-readable identifier for admin URLs
- `status`: `:draft | :open | :closed` initially; add `:archived` only if the
  remaining archive decision requires it
- `selection_mode`: initially `:single`
- `opens_at`, `closes_at`: optional timestamps for future scheduling
- `opened_at`, `closed_at`: actual lifecycle timestamps
- `results_published_at`: nullable timestamp controlled by an explicit publish
  action
- timestamps

Important actions:

- `create_draft`
- `update_draft`
- `open`
- `close`
- `publish_results`

Lifecycle changes should be actions with validations, not unrestricted status
updates. For example, opening should fail if the poll has fewer than two
options or no eligible voters.

### `Nominator.Polls.Option`

Materializes every selectable choice for a poll.

Suggested attributes and relationships:

- `id`: UUID
- `poll_id`: required relationship
- `label`: required display snapshot
- `description`: optional text
- `position`: integer for deterministic ordering
- `active`: boolean, primarily for drafts
- timestamps

The first release supports text options only. A later member-nomination feature
can add an optional `member_id` relationship while retaining `label` as the
historical display snapshot.

Identity: unique `[:poll_id, :position]`.

### `Nominator.Polls.Eligibility`

Snapshots who may vote in a poll.

Suggested fields:

- `id`: UUID
- `poll_id`
- `member_id` referencing `Member`
- timestamps

Identity: unique `[:poll_id, :member_id]`.

Do not derive eligibility from the live roster on every request. A snapshot
prevents adding, deleting, or changing a member from silently changing a poll
that is already open. A draft action can populate eligibility from all members
or selected individuals. Group-based selection can be added later if needed.

### `Nominator.Polls.AccessGrant`

Provides a revocable, poll-and-member-specific link.

Suggested fields:

- `id`: UUID
- `poll_id`
- `member_id`
- `token`: random UUID or higher-entropy opaque token
- `revoked_at`, `expires_at`: optional timestamps
- timestamps

Identity: unique token and unique `[:poll_id, :member_id]`.

Recommended public route:

```text
/polls/:poll_id/vote/:token
```

The server must verify that the grant belongs to the poll, identifies the same
member as the eligibility/ballot records, and is not revoked or expired. Voting
additionally requires that the grant's member has not already submitted a
ballot. An existing ballot does not invalidate the grant for viewing published
results. No member ID supplied by the browser may override the member identified
by the grant.

### `Nominator.Polls.Ballot`

Represents one eligible voter's submission state for one poll.

Suggested fields:

- `id`: UUID
- `poll_id`
- `member_id`
- `submitted_at`
- timestamps

Identity: unique `[:poll_id, :member_id]`.

A ballot may be created when eligibility is generated or lazily on submission.
Creating it eagerly simplifies progress reporting; creating it lazily reduces
rows. The recommendation is lazy creation inside a transaction when the voter
submits.

### `Nominator.Polls.Selection`

Stores choices belonging to a ballot.

Suggested fields:

- `id`: UUID
- `ballot_id`
- `option_id`
- `position` or `rank`: nullable until multi/ranked voting is introduced
- timestamps

For the first single-choice release, enforce one selection per ballot. Keeping
this separate from `Ballot` adds a small amount of work now but prevents another
schema rewrite when multiple-choice or ranked polls arrive.

## Relationship overview

```text
Poll
├── has many Options
├── has many Eligibility records ──> Member
├── has many AccessGrants ─────────> Member
└── has many Ballots ──────────────> Member
                              └── has many Selections ──> Option
```

Every selection is valid only when:

- the poll is open;
- the ballot voter is eligible for that poll;
- the option belongs to that poll;
- the access grant belongs to the same poll and member as the ballot; and
- the ballot has not already been submitted.

These checks must live in domain actions/changes, not only in LiveView event
handlers.

## Domain and naming changes

### Recommended domain boundary

Create a dedicated Ash domain for poll configuration and voting. The module
names below use `Nominator` only as an illustration; the new project should use
its own application namespace.

Possible modules:

```text
Nominator.Polls
Nominator.Polls.Poll
Nominator.Polls.Option
Nominator.Polls.Eligibility
Nominator.Polls.AccessGrant
Nominator.Polls.Ballot
Nominator.Polls.Selection
Nominator.Polls.Ballots
Nominator.Polls.Results
```

Add a separate member-management domain or context rather than carrying the
current swimmer/family administration model into the new project.

### `Swimmer` versus `Member`

The new project should use `Member` from the beginning. Nominator does not need
to be renamed or migrated because it remains the swimmer-specific proof of
concept.

Avoid adding Household or Family to the new core unless distribution
requirements later prove it necessary. The approved access model is directly
between a poll and a member.

## Admin experience

Start with separate route-level LiveViews rather than recreating Nominator's
all-in-one dashboard.

### Routes

```text
/admin                         Overview and active polls
/admin/members                 Member list
/admin/polls                   Poll list
/admin/polls/new               Create poll
/admin/polls/:id               Poll summary
/admin/polls/:id/edit          Draft configuration
/admin/polls/:id/options       Manage choices
/admin/polls/:id/electorate    Select eligible voters
/admin/polls/:id/results       Results and turnout
```

All routes belong in an authenticated admin live session. The authentication
pattern proven in Nominator can be reused conceptually, but should be configured
and tested independently in the new project.

### Poll creation workflow

1. Enter title and description.
2. Add and order text options.
3. Select eligible members.
4. Review the generated member access grants.
5. Preview the ballot.
6. Open the poll.
7. Monitor turnout and results.
8. Close the poll and publish results when ready.

Drafts may be freely edited. Once open, option and electorate changes should be
blocked. Closing changes lifecycle state without automatically publishing
results. Reopening behavior remains a product decision.

## Voting experience

Replace the hard-coded `VoteLive` with a poll-aware LiveView.

The member-specific link should load:

- poll title, description, and status;
- the access grant and member it identifies;
- poll options;
- existing ballot/submission state per voter; and
- instructions generated from selection mode and finality rules.

For the first release, render text options as radio cards or a select list.
Member-backed nomination search is a later option renderer and does not need to
be designed into the initial UI.

Server submission should be one transactional domain action such as:

```elixir
Nominator.Polls.submit_ballot(poll, access_grant, voter, option_ids)
```

The action should create the ballot and selections atomically and return a
duplicate-submission error if another request wins the race.

## Results and live updates

Change results from `Results.list/0` to `Results.for_poll/1`.

For single-choice polls:

- group selections by option;
- include zero-vote options when the administrator requests full results;
- calculate ranks and percentages within that poll only;
- calculate turnout as submitted ballots divided by eligible voters; and
- decide how ties are presented.

Administrators may see provisional results while a poll is open. Members may
see results only when the poll is closed, `results_published_at` is set, and
their access grant is still valid. Publishing must not reopen or modify any
ballot. A closed-but-unpublished poll shows a neutral “results are not yet
available” state through the same member link.

Use poll-scoped PubSub topics:

```text
poll:<poll_id>:status
poll:<poll_id>:results
```

This prevents one poll's vote or status change from refreshing every open poll
page and admin screen.

## Greenfield strategy

The approved direction requires no application or vote-data migration. Keep
Nominator intact as the proof of concept, create clean initial migrations in a
new repository, and use this document as the product/domain starting point.

Do not copy Nominator's `Vote`, `VotingSettings`, `Swimmer`, `Family`, or global
family-token model into the new schema. Reuse lessons and selected UI patterns,
not its domain constraints.

### Contingency: importing Nominator data later

If importing historical proof-of-concept votes later becomes valuable, treat it
as a separate import feature rather than a prerequisite for launch:

1. Create the new tables without changing old tables.
2. Create a legacy “Most Inspirational Swimmer 2026” poll.
3. Create one option per existing swimmer, storing the swimmer relationship and
   name snapshot.
4. Map swimmers to members and snapshot eligibility.
5. Create poll-and-member-specific access grants only if historical member
   access is actually required.
6. Convert each old vote into one ballot plus one selection.
7. Verify counts candidate-by-candidate and total-by-total.
8. Reconcile imported counts without modifying the source database.

The source Nominator database should remain read-only during any import.

## Complexity levels

### Level 1 — Extend Nominator with multiple swimmer polls

**Complexity: Medium**

Scope:

- Add `Poll`.
- Associate settings and votes with a poll.
- Change duplicate identity to `[:poll_id, :voter_id]`.
- Scope ballot loading, results, status, routes, and PubSub by poll.
- Keep swimmers as both voters and options.

Benefits:

- Supports a new swimmer award each season.
- Smallest change from the current application.

Limitations:

- Cannot represent “2027 theme” without fake swimmer records or an additional
  redesign.
- Continues using global family tokens and derived eligibility unless more work
  is added.

This is documented for comparison and is not recommended under the approved
greenfield direction.

### Level 2 — Generic single-choice polls

**Complexity: High — recommended target**

Scope:

- Add Poll, Option, Eligibility, AccessGrant, Ballot, and Selection.
- Support administrator-defined text options.
- Add poll creation, option management, electorate selection, preview, lifecycle,
  turnout, and scoped results.
- Build the member-specific public ballot and admin workflows.

Benefits:

- Supports themes, activities, dates, locations, and similar single-choice
  decisions.
- Establishes strong data boundaries and historical snapshots.
- Leaves room for additional selection modes.

This is the best balance between product flexibility and controllable scope.

### Level 3 — General polling platform

**Complexity: Very high**

Adds some combination of:

- multiple-choice limits;
- ranked-choice voting and alternative tally algorithms;
- write-ins and moderation;
- scheduled opening/closing;
- anonymous versus identifiable ballots;
- reusable audience segments;
- multiple teams/organizations and tenant isolation;
- poll templates and duplication;
- public result pages and exports;
- reminders, invitation delivery, and bounce tracking;
- audit logs, role-based administration, and destructive-action history.

This level changes the product from a team utility into a platform. It should be
driven by concrete requirements, not implemented speculatively.

## Major challenges and risks

### Data integrity

Poll, option, voter, access grant, and selection IDs all come from the browser.
They must be validated together inside one domain action. Independent lookups in
LiveView leave room for cross-poll submissions and race conditions.

### Historical accuracy

Member names and group assignments change. Decide which values are live
relationships and which are snapshots. Poll option labels and eligibility
should generally be snapshots once a poll opens.

### Privacy and ballot secrecy

The proposed first release stores an identifiable member ballot so it can
enforce one final vote. A generic polling feature must explicitly decide whether
votes are identifiable. True anonymous voting requires a different model that
can prove eligibility/one-use without retaining a direct voter-to-selection
relationship.

### Token security

Nominator's permanent family tokens would become increasingly sensitive as more
polls are added. Poll-and-member-specific revocable grants reduce blast radius.
Tokens must not appear in
logs, analytics URLs, or referrer headers sent to third parties.

### Poll mutability

Editing options after voting starts can invalidate meaning and results. Enforce
draft/open/closed transitions in Ash actions and freeze options/electorate at
open time.

### Deletion semantics

Deleting members, options, or polls with historical ballots needs a policy.
Prefer archive/deactivate behavior and restrictive foreign keys over
cascading deletion of election history.

### SQLite and deployment

Choose the new project's production database before implementation. SQLite can
fit a single-node, modest-volume deployment; horizontal deployment or heavy
concurrent voting requires a deliberate database and PubSub architecture.

### UI complexity

Keep poll controls, results, and member management on separate route-level
LiveViews rather than building one expanding dashboard or a large collection of
LiveComponents.

## Testing requirements

At minimum, add coverage for:

- poll lifecycle transitions and invalid transitions;
- opening without options or eligible voters;
- option and electorate immutability after opening;
- valid poll-specific access grants and rejected cross-poll tokens;
- rejected voters outside the eligibility snapshot;
- rejected options belonging to another poll;
- concurrent duplicate submissions;
- one ballot per voter per poll;
- text-option ballots;
- poll-scoped results, ties, percentages, and zero-vote options;
- member result visibility before and after publication;
- revoked grants denied for both voting and result access;
- turnout calculations;
- status and result PubSub isolation between polls;
- archived poll behavior;
- authenticated protection for every poll-management route.

## Recommended delivery plan

### Phase 0 — Bootstrap and remaining decisions

**Complexity: Small**

- Create the new Phoenix/Ash repository with generic naming.
- Resolve the remaining decision list above.
- Record Nominator as a separate proof of concept; do not share its database.
- Configure administrator authentication and the test foundation.

### Phase 1 — Poll foundation

**Complexity: Medium**

- Add Poll and Option resources.
- Add lifecycle actions and validations.
- Build authenticated poll list/create/edit/options pages.
- Keep polls in draft; do not change public voting yet.

### Phase 2 — Electorate and access

**Complexity: Medium to high**

- Add Eligibility and AccessGrant.
- Build electorate selection and ballot preview.
- Generate poll-and-member-specific revocable links.
- Add access and cross-poll security tests.

### Phase 3A — Ballot domain and submission integrity

**Complexity: Medium to high**

- Add Ballot and Selection resources.
- Add a unique ballot identity for `[:poll_id, :member_id]`.
- Associate selections with ballots and options from the same poll.
- Implement ballot submission as one transactional domain operation.
- Require an open poll, a valid poll-scoped grant, an eligible member, and
  exactly one option belonging to the poll.
- Treat submitted ballots as final and reject duplicate submissions.
- Protect the one-ballot rule against concurrent requests.
- Add domain tests for invalid grants, ineligible members, cross-poll options,
  duplicate submissions, and concurrent submissions.

Phase 3A is complete when a ballot can be submitted safely through the domain
API without relying on a LiveView or browser-supplied member identity.

### Phase 3B — Public voting experience and cutover

**Complexity: Medium to high**

- Add the public `/polls/:poll_id/vote/:token` route and poll-aware LiveView.
- Resolve the member exclusively from the access grant in the URL.
- Render single-choice text options as accessible radio cards.
- Add a review step that clearly explains submission finality.
- Show distinct states for invalid or revoked links, draft polls, open polls,
  successful submissions, duplicate submissions, and closed polls awaiting
  published results.
- Build the member-facing interface responsively from the approved mockup.
- Add LiveView tests for the complete voting journey and all denied states.

Phase 3B is complete when an eligible member can follow a private link, review
the ballot, submit one final vote, and receive a clear outcome. Results,
turnout, closing controls, and publication remain Phase 4 responsibilities.

### Phase 4 — Results and operations

**Complexity: Medium**

- Add poll-scoped results and turnout.
- Scope PubSub events by poll.
- Add close and explicit publish-results controls.
- Add member-visible published results and operational tests.
- Add link distribution/email and exports only if required.

### Phase 5 — Harden and iterate

**Complexity: Small to medium**

- Verify concurrency, token handling, authorization, and production behavior.
- Add audit/operational logging without logging access tokens.
- Update seeds, README, deployment, and operator documentation.
- Reassess member-backed options only after the text-option flow is proven.

## Rough impact map

| Area | Expected impact |
| --- | --- |
| Ash resources | 7 initial resources: Member, Poll, Option, Eligibility, AccessGrant, Ballot, Selection |
| Migrations | Clean initial schema in the new project; no legacy data dependency |
| Public LiveView | Substantial rewrite into poll-aware loading/submission |
| Admin LiveViews | Split dashboard; add poll CRUD, options, electorate, and results pages |
| JavaScript | Little initially; optional option-ordering enhancements later |
| Authentication | Configure new admin authentication using the proven Nominator pattern |
| Email | Poll-specific links, templates, delivery tracking, and resend behavior |
| Tests | Domain, LiveView, access-control, publication, and concurrency coverage |
| Documentation | Admin workflow, lifecycle rules, link security, and operator runbook |

## Recommendation

Proceed with a **new project implementing Level 2: generic single-choice
polls**, delivered through the phases above. Keep Nominator unchanged as a
working proof of concept and reference implementation for selected Phoenix/Ash
patterns.

Begin with Member, Poll, text Option, Eligibility, AccessGrant, Ballot, and
Selection resources. Use one revocable grant per member and poll, final ballots,
manual open/close, and explicit post-close result publication. Defer
member-backed options and broader platform features until this complete flow is
in use.
