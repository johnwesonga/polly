# Public Result Pages — Technical Specification

## Status

Implemented. The initial release includes private-default result visibility,
audited public/credentialed transitions for closed polls, the aggregate-only
public projection, the unauthenticated slug route, no-store and no-index
headers, administrator sharing controls, withdrawal, and automated privacy and
authorization coverage. Additional telemetry and optional future extensions
remain follow-up work.

## Summary

Allow anyone with a public results URL to view a poll's published aggregate results without signing in and without presenting a private voting token.

Public access is separate from result publication. `results_published_at` continues to answer **whether** results are available, while a new `result_visibility` setting answers **who** may view them. Existing and newly created polls default to `credentialed`, so this feature does not silently expose results that were previously available only through member voting links.

The public page is read-only and aggregate-only. It reuses `Polly.Polls.Results` as the source of result semantics and must never expose members, eligibility records, access grants, private URLs, ballots, or combinations of selections from an individual ballot.

This is a medium-complexity feature. The page itself is straightforward, but the authorization boundary, publication lifecycle, privacy defaults, URL stability, caching, and multiple-choice semantics must be explicit.

## Goals

- Provide a stable, shareable results URL that requires no voting credentials.
- Require an explicit administrator choice before a poll can expose results publicly.
- Display only closed, published, aggregate results.
- Reuse the same result projection as the administrator and credentialed-member views.
- Support both single-choice and multiple-choice polls.
- Preserve compatibility with future anonymous-choice polls.
- Make unavailable polls indistinguishable from unknown polls to unauthenticated visitors.
- Record changes to public visibility in the administrator audit trail.

## Non-goals

- Public voting or voting without an access grant.
- Showing provisional results while a poll is open.
- Publishing member names, emails, eligibility, participation, ballots, or private URLs.
- Showing which options appeared together on a multiple-choice ballot.
- Discoverable directories of public polls.
- Search-engine indexing in the first iteration.
- Comments, reactions, social sharing integrations, or embedded charts.
- Custom public-page branding or per-poll themes.
- Replacing the authenticated administrator results page.
- Certifying results, resolving ties, enforcing quorum, or declaring election winners.

## Terminology and lifecycle

Result availability has two independent dimensions:

| Concern | Field | Meaning |
| --- | --- | --- |
| Publication | `results_published_at` | The closed poll's results have been released. |
| Audience | `result_visibility` | Published results require a voting credential or are publicly accessible. |

Add `Polly.Polls.Poll.ResultVisibility`, an `Ash.Type.Enum` with:

- `:credentialed` — the existing behavior; a valid voting link is required;
- `:public` — the published aggregate results are also available at the public URL.

Add the following poll attribute:

```elixir
attribute :result_visibility, Polly.Polls.Poll.ResultVisibility do
  allow_nil? false
  public? true
  default :credentialed
end
```

The default is intentionally private. The database migration must backfill all existing polls to `credentialed` before making the column non-null.

### Availability matrix

| Poll state | Published | Visibility | Public result page |
| --- | --- | --- | --- |
| Draft | No | Either | Not available |
| Open | No | Either | Not available |
| Closed | No | Either | Not available |
| Closed | Yes | Credentialed | Not available |
| Closed | Yes | Public | Available |

`publish_results` remains a closed-poll action. Setting visibility to public does not publish, close, or otherwise advance a poll's lifecycle.

## Visibility management

The first iteration should expose the visibility choice on the administrator results page, close to the existing publish-results control. The wording should describe the audience rather than use a bare checkbox:

- **Voting-link holders only** — members need their private voting link to see published results.
- **Anyone with the public results link** — no sign-in or voting link is required.

Visibility may be changed while a poll is closed, both before and after publication. This supports an emergency withdrawal path without pretending that already viewed or cached information can be recalled:

- `credentialed -> public` makes already-published results immediately available;
- `public -> credentialed` makes the public route immediately unavailable;
- changing visibility before publication only affects what happens after publication.

Changing visibility requires the existing `:publish_results` permission, a confirmation dialog, and an audit event. The confirmation for enabling public access must explicitly state that anyone with the URL will be able to view the aggregate results.

Draft and open polls may show the planned visibility as read-only configuration if it is introduced into the poll form later, but the initial implementation does not need to make it editable there.

Suggested Poll actions:

```elixir
update :make_results_public do
  accept []
  require_atomic? false
  validate attribute_equals(:status, :closed)
  change set_attribute(:result_visibility, :public)
end

update :make_results_credentialed do
  accept []
  require_atomic? false
  validate attribute_equals(:status, :closed)
  change set_attribute(:result_visibility, :credentialed)
end
```

The actions should reject no-op transitions and append `poll.results_made_public` or `poll.results_made_credentialed` audit events. They should broadcast a poll-status or result-visibility event so an open public page becomes unavailable promptly after withdrawal.

## Public URL and routing

Use the poll slug rather than its UUID:

```text
/polls/:slug/results
```

Add the LiveView to the unauthenticated browser scope:

```elixir
live "/polls/:slug/results", PublicPollResultsLive, :show
```

The slug is appropriate because it is readable, globally unique, regenerated only while a poll is a draft, and stable after the poll opens. The page must generate links from the persisted slug rather than recomputing one from the title.

The public URL is not a secret. Security must depend on the poll's state, publication timestamp, and visibility—not on difficulty guessing the slug.

## Authorization and data boundary

Do not put `authorize?: false` queries directly in the public LiveView. Add one explicit public boundary, such as:

```elixir
Polly.Polls.PublicResults.fetch_by_slug(slug)
```

The boundary must return a safe projection only when all of the following are true:

- the slug matches a poll;
- `status == :closed`;
- `results_published_at` is not `nil`; and
- `result_visibility == :public`.

The preferred implementation is a dedicated Ash read action authorized for unauthenticated access only when these resource filters hold. If the result aggregation service must perform trusted internal reads, that bypass remains encapsulated in `PublicResults`; the LiveView must never receive unrestricted poll relationships.

Return a purpose-built value containing only fields required by the page, for example:

```elixir
%{
  poll_id: poll.id,
  slug: poll.slug,
  title: poll.title,
  description: poll.description,
  closed_at: poll.closed_at,
  results_published_at: poll.results_published_at,
  selection_mode: results.selection_mode,
  minimum_selections: poll.minimum_selections,
  maximum_selections: poll.maximum_selections,
  ballot_count: results.ballot_count,
  eligible_count: results.eligible_count,
  turnout_percentage: results.turnout_percentage,
  total_selections: results.total_selections,
  options: results.options
}
```

Do not include or load:

- `eligibilities.member`;
- `access_grants` or token fields;
- ballots with `member_id`;
- raw selections grouped by ballot;
- invitation deliveries; or
- administrator audit metadata.

The public boundary should be added to authorization-coverage tests so future changes cannot accidentally replace it with a broad unauthenticated poll read.

## Unavailable-page behavior

Unknown, draft, open, unpublished, credentialed-only, and withdrawn polls must all produce the same generic not-found response.

The response must not reveal:

- whether the slug belongs to a poll;
- the poll's current state;
- whether results exist but are private; or
- whether results were previously public.

For LiveView, raise `PollyWeb.NotFoundError` or use the application's established 404 mechanism during mount. The disconnected HTTP response should have status `404`; do not render a successful `200` page containing “results are not published.”

## Page presentation

Use the Touchpad visual language already used by the member and administrator result views. The public page should contain:

- Polly branding and a clear **Published results** eyebrow;
- poll title and optional description;
- closed date and results-published date;
- selection instructions or mode summary;
- eligible-member count, submitted-ballot count, and turnout;
- total selections for multiple-choice polls;
- one result row per active option, in configured option order;
- selection count and percentage for each option; and
- a plain-language explanation of the percentage denominator.

For a single-choice poll, an option percentage is its share of submitted ballots. For a multiple-choice poll, it is the percentage of submitted ballots that selected that option. Multiple-choice percentages may therefore total more than 100%. This wording must stay aligned with `Polly.Polls.Results` and the CSV result export.

Use “leading option” or “tied for lead,” not “winner,” unless Polly later implements explicit winner and tie rules.

The page must not render voting controls, the member's name, a sign-in prompt, an access-token field, or navigation into administrator pages.

## Empty and inconsistent states

A published poll with zero submitted ballots should still render its options and display zero counts and percentages.

Opening validation should prevent a legitimate closed poll from having no active options. If inconsistent historical data has no active options, fail closed with the generic not-found response and log an operational error; do not expose a misleading public page.

If the result projection fails, return a generic server error and log the poll ID internally. Do not fall back to raw ballots or partial counts.

## Privacy and security

- Add `noindex, nofollow` metadata in the first iteration to reduce accidental search-engine discovery.
- Do not include access tokens in public URLs, HTML, logs, telemetry, analytics, or canonical links.
- Do not derive the public URL from an existing voting URL by removing or retaining token fragments.
- Do not expose ballot timestamps or other fields that could enable correlation attacks.
- Use aggregate queries through the established results service rather than serializing relationships.
- Escape all poll-authored content through HEEx; do not render descriptions as raw HTML.
- Apply the application's normal secure response headers.
- Consider rate limiting separately if automated scraping becomes a concern.
- Treat visibility withdrawal as preventing future access, not as deletion from browser caches, screenshots, or third-party archives.

Aggregate publication can still reveal information in very small electorates. The enable-public confirmation should warn administrators about this inference risk.

## Caching

The first iteration should use:

```text
Cache-Control: private, no-store
```

This makes visibility withdrawal predictable and avoids serving public results from a shared cache after access is removed. Results are final after closure, but privacy controls take precedence over cache optimization.

A later iteration may use short-lived public caching with explicit invalidation after visibility changes. That optimization is out of scope until the application has a tested invalidation path.

## Audit trail

Record safe events for:

- `poll.results_made_public`;
- `poll.results_made_credentialed`.

The event should contain the poll identity, actor identity, old visibility, new visibility, and timestamp. It must not contain access tokens, member details, ballots, or public-page visitor information.

Anonymous page views are not administrator actions and should not create audit records in the first iteration. Normal request logs and aggregate telemetry are sufficient.

## Observability

Track aggregate metrics for:

- successful public-result loads;
- not-found public-result loads;
- result-projection failures; and
- visibility changes.

Do not use the raw slug as a metric label because it creates unbounded cardinality. Poll IDs may appear in structured application logs when needed for diagnosis, but access tokens and member data must never appear.

## Implementation phases

### Phase 1 — Persistence and lifecycle actions

- Add `ResultVisibility` with `:credentialed` and `:public` values.
- Add and backfill `polls.result_visibility` with a private default.
- Add closed-poll visibility actions and permission policies.
- Append visibility audit events.
- Add resource and migration tests.

This phase must not make any result page public on its own.

### Phase 2 — Public result projection and route

- Add the constrained public read action or `PublicResults` service.
- Add `/polls/:slug/results` outside authenticated live sessions.
- Render aggregate results using the existing result projection.
- Return a uniform 404 for every unavailable state.
- Add `noindex` and no-store behavior.
- Add authorization-coverage and privacy-boundary tests.

### Phase 3 — Administrator controls and sharing UX

- Add the visibility control and confirmation dialog to the administrator results page.
- Show the public URL only when results are published and visibility is public.
- Add a copy-link action using a Phoenix JavaScript hook or existing clipboard behavior.
- Explain small-electorate inference risk and visibility withdrawal limitations.
- Verify role-aware controls for administrators with `:publish_results` permission.

### Phase 4 — Operational hardening

- Add result-page telemetry and structured failure logging.
- Verify withdrawal behavior for already-open LiveView sessions.
- Add accessibility, responsive-layout, and system-dark-mode coverage.
- Perform a security review for relationship leakage and cache behavior.

## Test plan

### Poll resource tests

- New and migrated polls default to `:credentialed`.
- A closed poll can change between credentialed and public visibility.
- Draft and open polls cannot change result visibility through the closed-poll actions.
- No-op visibility changes fail clearly.
- Unauthorized actors cannot change visibility.
- Visibility changes append the expected audit events.

### Public boundary tests

- A closed, published, public poll is returned by slug.
- Unknown, draft, open, unpublished, credentialed, and withdrawn polls return the same not-found result.
- The returned projection contains no member, grant, token, ballot, or delivery records.
- Counts and percentages match `Polly.Polls.Results.for_poll/1`.
- Multiple-choice support rates use ballots as their denominator and may total more than 100%.
- A zero-ballot published poll returns zero-valued option results.

### LiveView tests

- The public route mounts without a user session or voting token.
- The page renders poll metadata, turnout, and option aggregates.
- It does not render voting controls or credential-bearing links.
- Unavailable states return 404 rather than a revealing status message.
- Single-choice and multiple-choice explanatory copy is correct.
- System dark mode and narrow-screen layouts remain legible.

### Administrator tests

- A permitted administrator can enable and withdraw public visibility after confirmation.
- A user without `:publish_results` cannot see or invoke the controls.
- The public URL appears only for a published public poll.
- Copying the URL never includes a voting token.
- Withdrawing visibility makes a previously working route unavailable.

## Acceptance criteria

The feature is complete when:

- no existing poll becomes public because of the migration;
- an administrator with the correct permission can deliberately make a closed poll's results public;
- an unauthenticated visitor can view only a closed, published, public poll by slug;
- all other poll states produce the same 404 behavior;
- the page matches the authoritative aggregate result projection for single- and multiple-choice polls;
- the public response and UI expose no voting credential or voter-level data;
- public visibility can be withdrawn and takes effect without a redeploy;
- visibility changes are audited; and
- automated tests cover authorization, lifecycle, privacy, result semantics, and withdrawal.

## Risks and likely issues

- **Accidental disclosure:** coupling public access directly to `results_published_at` would expose existing polls. The private visibility default prevents this.
- **Small-electorate inference:** aggregate results may reveal likely choices even without identities. The UI must warn administrators.
- **Stale public copies:** withdrawal cannot remove screenshots or third-party caches. No-store headers reduce but do not eliminate this risk.
- **Authorization drift:** a broad unauthenticated `Poll.read` action could leak more than the public page needs. Use a constrained action and safe projection.
- **Slug changes:** links generated while a poll is still a draft can become stale. Only show a shareable URL after publication, when the slug is stable.
- **Percentage ambiguity:** multiple-choice percentages are support rates per ballot, not shares of all selections. Keep the explanatory copy and projection centralized.
- **Future anonymity work:** a public serializer that starts from raw ballots could defeat anonymous-choice guarantees. Keep it aggregate-only from the outset.
- **Live withdrawal:** an already-mounted LiveView may retain rendered data unless it subscribes to visibility changes or rechecks authorization. Test this explicitly.

## Future extensions

- Optional search-engine indexing.
- Organizer-authored publication notes.
- Embeddable aggregate charts backed by the same public projection.
- Custom share images and social metadata.
- Public CSV downloads with the same visibility checks.
- Expiring public-result availability windows.
- Random, non-title-derived public aliases for sensitive use cases.
- Configurable suppression for electorates below a privacy threshold.

## Open questions

- Should future polls configure intended result visibility during draft creation so voters know the publication audience before voting?
- Should Polly enforce a minimum electorate size before allowing public publication?
- Should public visibility changes require owner approval, or is `:publish_results` permission sufficient?
- Should a later iteration allow permanent unpublishing, distinct from returning visibility to credentialed access?
