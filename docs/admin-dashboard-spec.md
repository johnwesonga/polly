# Administration Dashboard — Technical Specification

## Status

Phases 0–4 implemented; phases 5–6 proposed.

## Summary

Replace the basic `/admin` landing page with a role-aware operational dashboard that answers three questions:

1. What is happening now?
2. What requires my attention?
3. What am I permitted to do next?

The dashboard summarizes existing Polly state and links to authoritative management screens. It must not become a second implementation of poll lifecycle, result calculation, invitation delivery, audit, or administrator management.

## UI mockups

- [Responsive HTML prototype](mockups/admin-dashboard.html)
- [Owner dashboard image](mockups/admin-dashboard-owner.png)

## Complexity assessment

This is a **medium-complexity** feature. The interface itself is straightforward, but its data crosses several authorization and privacy boundaries. A single dashboard is rendered for owners, administrators, auditors, and operators with substantially different permissions.

The main risks are excessive database queries, leaking information through counts, duplicating domain logic, and presenting stale operational state as authoritative. The work is divided into phases so each data source and role boundary can be verified independently.

## Goals

- Make `/admin` a useful daily operational entry point.
- Highlight work requiring attention instead of showing only navigation cards.
- Present poll, delivery, account, and job summaries according to the current user's permissions.
- Link every summary to its authoritative management page.
- Reuse existing result, authorization, audit, and invitation semantics.
- Keep aggregate voter information separate from individual choices.
- Remain responsive with a growing number of polls, members, audit events, and jobs.

## Non-goals

- Replacing poll, member, administrator, audit, or Oban management screens.
- Editing resources directly inside dashboard cards.
- Displaying individual ballots, selections, private URLs, access tokens, or invitation credentials.
- Providing mutable Oban controls.
- Real-time charts or PubSub subscriptions in the first iteration.
- Historical analytics, cross-poll comparisons, or custom dashboard layouts.
- Scheduled opening, closing, reminders, or archival.
- Treating provider acceptance as proof that an email reached an inbox.

## Design principles

### Attention before statistics

The primary content is work that needs a decision. Raw totals are supporting context. Avoid vanity metrics such as lifetime ballot counts unless they directly help an administrator act.

### Role-aware composition

Cards must be omitted when the current user lacks the underlying permission. Hiding a card is not authorization: every service and Ash query must independently enforce its permission.

### Authoritative links

Dashboard cards link to existing filtered screens. Actions such as opening a poll, publishing results, changing roles, or retrying email remain on their dedicated pages.

### Aggregate privacy

Turnout may show submitted and eligible counts. The dashboard never shows who voted or how anyone voted. It must remain compatible with anonymous-choice polls.

## Information architecture

The dashboard is ordered as follows:

1. **Page heading and quick actions**
2. **Action required**
3. **Poll summary**
4. **Active polls**
5. **Recent activity**
6. **Account security and delivery health**

Sections with no visible cards are omitted. Empty states should say that no action is currently required rather than rendering zero-filled grids.

## Role matrix

| Section | Owner | Administrator | Auditor | Operator |
| --- | --- | --- | --- | --- |
| Quick actions | All permitted actions | Poll/member actions | Results and audit links | Job monitoring |
| Poll status counts | Yes | Yes | Yes | No |
| Poll attention | Yes | Yes | Read-only result-related items | No |
| Active poll turnout | Yes | Yes | Yes | No |
| Recent audit activity | Yes | No | Yes | No |
| Account security | Yes | No | No | No |
| Delivery/job health | Yes | Delivery summary | No | Yes |

The implementation derives visibility from `Polly.Accounts.Authorization`; it must not branch directly on role names.

## Dashboard data contract

Introduce a projection boundary such as:

```elixir
Polly.Administration.Dashboard.load(actor)
```

It returns only sections the actor may view:

```elixir
%{
  poll_counts: %{draft: 0, open: 0, closed: 0, unpublished: 0} | nil,
  attention_items: [%{kind: atom(), count: non_neg_integer(), destination: String.t()}],
  active_polls: [%{poll: Poll.t(), ballot_count: integer(), eligible_count: integer(), turnout: number()}],
  recent_events: [Event.t()] | nil,
  account_health: map() | nil,
  delivery_health: map() | nil
}
```

The exact struct may be split into smaller projections as the implementation grows. LiveView should not assemble domain rules from unrelated raw records.

## Metrics and attention rules

### Poll summary

- Draft polls
- Open polls
- Closed polls
- Closed polls with `results_published_at == nil`

Counts use database aggregation and the same visibility rules as `/admin/polls`. They must not load every poll and count with `Enum`.

### Poll attention

Initial actionable conditions:

- Draft poll with fewer than two active options
- Draft poll with no eligible members
- Open poll with no accepted invitation deliveries
- Open poll with failed invitation deliveries
- Closed poll with unpublished results

One poll may satisfy multiple conditions. Summary counts should state whether they count polls or incidents. The first iteration should count polls per condition.

Readiness rules must live in a reusable polls projection or service. The dashboard must not redefine the validations that govern opening a poll.

### Active polls

Show at most five open polls, ordered by `updated_at` descending and then title until Polly records a dedicated `opened_at` timestamp. Each row includes:

- title;
- submitted ballots;
- eligible members;
- turnout percentage;
- invitation delivery summary; and
- a permission-aware destination, normally access management or results.

Use `Polly.Polls.Results` for turnout semantics. Do not issue one result query per poll; add a batched aggregate query before this section ships.

### Account security

Owner-only counts:

- active owners;
- disabled accounts;
- unconfirmed accounts;
- pending administrator invitations; and
- administrator invitations expiring within 48 hours.

When only one active owner remains, render a high-priority warning linking to `/admin/administrators`.

### Delivery and job health

Permitted summaries may include:

- queued invitation jobs;
- retrying jobs;
- discarded jobs;
- failed poll invitation deliveries; and
- administrator invitations queued but not yet accepted by the provider.

The card links to read-only Oban Web or the relevant invitation page. It never displays job arguments, raw errors containing credentials, or private recipient URLs.

### Recent activity

Show at most five audit events visible to the actor, using `Polly.Audit.humanize/1`. Link to `/admin/audit`. Do not add a new unrestricted audit query for the dashboard.

## LiveView implementation

`PollyWeb.AdminLive` remains the route owner for `/admin`.

On mount it:

1. receives the authenticated active actor;
2. calls the dashboard projection once;
3. assigns scalar counts and permission-aware quick actions; and
4. streams bounded active-poll, attention, and activity collections.

Every major section and actionable link receives a stable DOM ID. Stream containers use `phx-update="stream"` and are reset after an explicit refresh. The first iteration does not poll automatically.

Suggested IDs include:

```text
#admin-overview
#dashboard-quick-actions
#dashboard-attention
#dashboard-poll-summary
#dashboard-active-polls
#dashboard-recent-activity
#dashboard-account-health
#dashboard-delivery-health
```

Use existing Touchpad cards, pills, callouts, typography, and buttons. Remove inline styles from the current page and add focused CSS classes to `assets/css/polly.css`.

## Authorization and privacy

- `/admin` continues to require an active authenticated user.
- Each projection section checks the permission associated with its source data.
- Resource reads use the actor whenever a policy-backed read exists.
- Any necessary `authorize?: false` aggregate is contained in a reviewed service that first authorizes the actor and is added to `AuthorizationCoverage`.
- Operators cannot infer poll, member, result, audit, or administrator totals.
- Administrators cannot infer administrator-account or audit totals.
- Auditors cannot see invitation recipients, access links, or mutable actions.
- Counts must not reveal data hidden by the corresponding list page.

## Performance

- Use database counts and grouped aggregates rather than loading complete collections.
- Avoid per-poll queries for options, electorate, ballots, or deliveries.
- Bound active polls and recent events to five records.
- Target no more than one query per summary family in the final implementation.
- Record dashboard projection duration with telemetry if production data shows meaningful latency.
- Do not cache permission-sensitive dashboard output globally.

## Accessibility and responsive behavior

- Cards and warnings use semantic headings.
- Status cannot be communicated by color alone.
- Links describe their destination or action.
- Metric values include visible labels.
- Mobile layouts collapse to one column without horizontal scrolling.
- Empty and loading states remain understandable to screen readers.

## Implementation phases

### Phase 0 — Projection contract and query inventory

Purpose: establish a safe data boundary before changing the UI.

- Inventory existing queries and permissions for each proposed metric.
- Add `Polly.Administration.Dashboard` or equivalent projection modules.
- Implement database-backed poll status counts.
- Define stable structs/maps for dashboard sections.
- Add the service and any reviewed bypasses to `AuthorizationCoverage`.
- Test the four roles, disabled users, and missing actors at the service boundary.

Exit criteria: poll counts are correct, permission-filtered, and do not require loading all polls.

### Phase 1 — Poll summary and quick actions

Purpose: replace the basic navigation cards with a useful first dashboard.

- Add role-aware quick actions.
- Add draft, open, closed, and unpublished-result counts.
- Link metrics to filtered poll views.
- Add responsive dashboard card styles and stable IDs.
- Preserve the existing background-jobs entry point for permitted roles.

Exit criteria: every role sees only relevant actions and poll summaries; existing navigation remains available.

### Phase 2 — Action-required poll readiness

Purpose: tell poll managers what needs intervention.

- Add reusable readiness and attention projections.
- Surface missing options, missing electorate, unsent invitations, failed deliveries, and unpublished results.
- Link each condition to the screen where it can be resolved.
- Add a positive empty state when no action is required.

Exit criteria: attention counts agree with authoritative poll and invitation state, including empty and overlapping conditions.

### Phase 3 — Active poll operations

Purpose: provide a concise view of voting currently underway.

- Add a batched aggregate for up to five open polls.
- Display ballot count, eligible count, turnout, and delivery state.
- Add permission-aware access/results links.
- Verify aggregate privacy for identified and future anonymous-choice modes.

Exit criteria: active poll cards use existing turnout semantics with no per-poll query loop.

### Phase 4 — Audit and owner security

Purpose: surface recent consequential actions and account risks.

- Add the five most recent authorized audit events.
- Add owner-only account and pending-invitation counts.
- Warn when there is only one active owner.
- Warn about administrator invitations expiring within 48 hours.

Exit criteria: audit and account information is absent for unauthorized roles, and owner warnings link to the administrator page.

### Phase 5 — Delivery and job health

Purpose: give owners and operators a safe operational summary.

- Add grouped Oban job-state counts.
- Add failed and queued invitation-delivery counts.
- Link to read-only Oban Web and invitation management.
- Redact provider errors and omit job arguments.

Exit criteria: owners and operators can identify queue trouble without receiving mutable job access or credential-bearing data.

### Phase 6 — Hardening and observability

Purpose: verify the complete dashboard under production-like load and authorization conditions.

- Add query-count and representative large-dataset tests.
- Add telemetry for projection duration and failure status.
- Test stale data and partial subsystem failure behavior.
- Confirm all role combinations at the LiveView and service boundaries.
- Review copy, responsive layout, keyboard navigation, and dark mode.
- Update the roadmap status and operational documentation.

Exit criteria: the dashboard remains bounded, permission-safe, usable, and diagnosable with production-scale data.

## Test strategy

### Projection tests

- Poll counts cover every lifecycle and publication combination.
- Attention rules cover each condition and overlapping conditions.
- Aggregate turnout matches `Polly.Polls.Results`.
- Limits and sort order are deterministic.
- Each permission either returns its permitted section or `nil`/an explicit forbidden result.

### LiveView tests

- Each role sees the expected section IDs and does not see forbidden sections.
- Metric and attention links point to valid filtered destinations.
- Empty states render correctly.
- Active poll and audit collections use stable streamed IDs.
- Disabled and anonymous users cannot mount the dashboard.

### Privacy and security tests

- Rendered dashboard output contains no access tokens, invitation credentials, private URLs, ballot/member linkage, job arguments, or raw provider errors.
- Direct service calls cannot bypass role permissions.
- Hiding a card is never the only authorization control.

### Performance tests

- Query count remains bounded as poll volume grows.
- The projection does not load unbounded poll, ballot, delivery, job, or audit collections.
- Representative production-scale fixtures complete within an agreed threshold measured in CI or a dedicated benchmark.

## Rollout

Each phase is deployable independently. Phase 1 should ship before the richer attention logic so real usage can validate the information hierarchy. Later sections can be enabled as their projection tests pass; no feature flag is required unless a production dataset reveals unacceptable query cost.

## Open decisions

1. Should unpublished closed polls always be considered actionable, or can an administrator mark results as intentionally private?
2. What event defines “recently opened” when an explicit `opened_at` timestamp is unavailable?
3. Should low turnout become an attention condition, and if so, who configures the threshold?
4. Should the dashboard include archived polls after poll archiving ships, or keep them exclusively in the archive view?
5. Should operators see provider-level delivery counts, or only Oban queue state?
