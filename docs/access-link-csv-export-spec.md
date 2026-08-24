# Access-link CSV export feature specification

## Summary

Allow an authenticated administrator to export a poll's member access links as
a CSV file for controlled, private distribution outside Polly.

The export contains one row per eligible member with the member name, email
address, current link status, and a complete private voting URL when the member
has a usable access grant.

The CSV is a credential-bearing document. Anyone who obtains an active URL can
vote as the corresponding member, subject to the poll lifecycle and final
ballot rules. The feature therefore prioritizes explicit confirmation,
authorization, secret-safe implementation, and clear handling of revoked and
expired links.

## Complexity assessment

This is a **medium complexity** feature.

Generating CSV is straightforward. The risk comes from exporting many bearer
credentials at once. The implementation must correctly determine which grant
is usable, generate canonical public URLs without trusting request headers,
prevent spreadsheet formula injection, avoid token leakage through logs or
audit metadata, and ensure the download cannot be accessed by an unauthenticated
visitor.

The feature remains manageable if the first iteration is a direct download and
does not store generated exports or send them by email.

## Goals

- Let administrators distribute access links through an approved external
  process without copying links one at a time.
- Export one deterministic row for every member in the poll electorate.
- Clearly distinguish active, revoked, expired, and never-issued links.
- Include a private URL only when it is currently usable.
- Preserve CSV compatibility with common spreadsheet applications.
- Avoid retaining generated files or exposing grant tokens outside the
  download response.
- Keep export generation behind the existing administrator authorization
  boundary.

## Non-goals

- Sending voting links by email, SMS, chat, or another external service.
- Uploading the CSV to cloud storage.
- Retaining export files or providing an export-history download archive.
- Creating, reissuing, revoking, or repairing grants during export.
- Adding members to the electorate.
- Exporting ballots, selections, turnout, or voting results.
- Exporting revoked or expired token values.
- Password-protecting or encrypting the CSV file in the first iteration.
- Tracking whether an administrator successfully delivered each link.
- Supporting `.xlsx`, `.ods`, PDF, or printable label formats.
- Providing a public or token-authenticated export endpoint.

## Security model

An access link is a bearer credential. The URL contains the full poll ID and
grant token and identifies one eligible member to the public voting flow.

The export page must explain:

> This file contains private voting credentials. Anyone with a member's active
> link can access that member's ballot. Store and share the file securely.

The feature follows these rules:

- only an authenticated administrator may generate an export;
- the export is generated on demand and streamed or sent directly in the HTTP
  response;
- generated CSV contents are never persisted by Polly;
- raw URLs and tokens are never written to application logs, telemetry,
  exception metadata, flash messages, or audit-event metadata;
- revoked and expired token values are never included, even for diagnostic
  purposes;
- the browser response is marked private and non-cacheable; and
- the endpoint uses the configured public application origin rather than a
  request-supplied host header.

This feature cannot control what administrators do with a downloaded file.
Product copy must advise them to use an approved secure distribution channel
and delete local copies when no longer needed.

## Export scope

The export contains one row for every `Eligibility` belonging to the selected
poll, including members who have since become inactive. Eligibility is a poll
snapshot and must remain the source of export membership.

Roster members who are not eligible for the poll are excluded.

The export is available for draft, open, and closed polls:

- **Draft:** links may be distributed in preparation, but voting will remain
  unavailable until the poll opens.
- **Open:** active links can be used immediately.
- **Closed:** links remain listed for historical administration, but the poll
  lifecycle prevents new ballots.

If poll archiving is implemented, archived polls remain exportable from their
authorized access page. Archival retains history and does not change grant
state. The UI should make the archived and closed states clear before download.

An empty electorate does not produce a misleading header-only download. The UI
disables the export action and directs the administrator to configure the
electorate.

## CSV contract

### Encoding and format

- Media type: `text/csv; charset=utf-8`.
- Encoding: UTF-8.
- Delimiter: comma.
- Line ending: CRLF for broad spreadsheet compatibility.
- Header row: always present.
- Fields containing commas, quotes, or line breaks are quoted according to
  RFC 4180 conventions.
- Embedded quotes are escaped by doubling them.
- A standards-compliant CSV encoder such as the already adopted `NimbleCSV`
  dependency must be used. CSV rows must not be assembled with `Enum.join/2`.

The first iteration should include a UTF-8 byte-order mark only if manual
testing shows it is necessary for the supported spreadsheet applications. If
included, it appears once at the beginning of the response and is documented
in tests.

### Columns

Columns appear in this exact order:

```csv
name,email,link_status,private_url
```

`name`:

- the current member name;
- required because every `Member` has a name; and
- escaped for CSV and spreadsheet safety.

`email`:

- the current normalized member email;
- blank when the member has no email address; and
- never substituted with placeholder text such as “No email address.”

`link_status` is one of:

- `active` — a non-revoked, non-expired grant exists;
- `expired` — no usable grant exists and the latest grant has expired;
- `revoked` — no usable grant exists and the latest grant was revoked; or
- `not_issued` — the member has no access-grant history for this poll.

`private_url`:

- contains the full canonical voter URL only for `active` rows; and
- is blank for `expired`, `revoked`, and `not_issued` rows.

Example:

```csv
name,email,link_status,private_url
Jamie Rivera,jamie@example.com,active,https://polls.example.com/polls/POLL_ID/vote/SECRET_TOKEN
Morgan Lee,morgan@example.com,revoked,
Taylor Kim,,not_issued,
```

### Spreadsheet formula safety

CSV quoting alone does not prevent spreadsheet formula execution. Before
encoding, any exported text cell beginning with `=`, `+`, `-`, or `@` after
leading whitespace must be neutralized using a documented spreadsheet-safe
prefix such as a single quote.

This protection applies to member names and email values as well as future
columns. Canonical private URLs begin with `https://` in production, but the
same generic protection should still be applied to every string cell.

The transformation affects only the exported representation. It never updates
the member or grant record.

## Link-status resolution

Grant status must be calculated at export time. The export must not rely on the
current LiveView's `grants_by_member` assign because that view currently focuses
on non-revoked grants and may not distinguish expiration.

For each eligible member:

1. Load all grants for the same poll and member, ordered newest first.
2. Find a grant where `revoked_at` is `nil` and `expires_at` is either `nil` or
   later than the current UTC time.
3. If a usable grant exists, classify the row as `active` and generate its URL.
4. Otherwise inspect the newest grant:
   - no grant means `not_issued`;
   - a non-revoked grant whose expiration is in the past means `expired`;
   - a revoked grant means `revoked`.

If unexpected historical data contains more than one usable grant, use the
newest usable grant and emit an operational signal without including tokens.
The export must not attempt to revoke or repair data.

Expiration comparisons use a single captured `DateTime.utc_now/0` value for the
whole export so rows are internally consistent.

The status represents credential usability, not poll lifecycle. An active
grant for a draft or closed poll is still reported as `active`; separate poll
status copy explains whether voting is currently open.

## Ordering and determinism

Rows are sorted by:

1. case-insensitive member name;
2. normalized email, with blank email last; and
3. member ID as a stable final tie-breaker.

The same unchanged poll exported twice should produce the same row order and
values, except for response metadata and a filename date if used.

## Filename

Use a safe filename derived from the poll slug:

```text
<poll-slug>-access-links-YYYY-MM-DD.csv
```

Example:

```text
annual-board-vote-access-links-2026-08-24.csv
```

The existing slug character contract makes it suitable for a filename. The
server supplies `Content-Disposition: attachment` and must not accept a
filename from browser parameters.

## Administrator workflow

### Access-links page

The existing poll access page adds an **Export CSV** button near the active and
eligible counts.

The button is shown when at least one eligible member exists. It remains
available when some or all grants are revoked or expired because those statuses
are useful distribution information.

Selecting the button opens or triggers a confirmation containing:

- poll title and lifecycle status;
- eligible-member count;
- active-link count;
- revoked, expired, and not-issued counts;
- a warning that the file contains bearer credentials; and
- a reminder that blank-email members require another private delivery method.

The final action is labelled **Download private access CSV**, not simply
“Export,” so the sensitivity is clear.

The first iteration may use the browser's existing `data-confirm` behavior if
the confirmation can present the required warning clearly. A dedicated modal
is preferred when summary counts are displayed.

### Download result

Successful confirmation starts a normal browser download without navigating
away from the access page. A download should not display tokens in flash
messages or query parameters.

The access page remains usable after download. Export generation does not
change grants, poll state, or member state.

If no eligible members exist, the disabled state says why and retains the
existing link to configure the electorate.

## HTTP design

Use an authenticated controller endpoint rather than attempting to return a
file directly from a LiveView event:

```text
GET /admin/polls/:poll_id/access-links.csv
```

The route belongs to the browser pipeline and must load the authenticated actor
from the session. If the existing authenticated LiveView session does not
protect controller routes, add an explicit controller authentication plug or
authenticated controller scope.

The controller:

1. retrieves the current actor;
2. calls the export domain service with the poll ID and actor;
3. receives encoded CSV iodata and a server-generated filename;
4. sets secure response headers; and
5. sends the attachment.

Required response headers include:

```text
Content-Type: text/csv; charset=utf-8
Content-Disposition: attachment; filename="..."
Cache-Control: private, no-store, max-age=0
Pragma: no-cache
X-Content-Type-Options: nosniff
Referrer-Policy: no-referrer
```

The endpoint path contains only the poll ID. Tokens and member data must never
appear in request paths or query strings.

An unauthenticated request redirects to sign-in or returns the application's
standard unauthorized response without generating CSV. An authenticated actor
who cannot read the poll receives a not-found or forbidden response consistent
with other administrator routes.

## Domain design

CSV generation belongs in a poll-domain service, conceptually:

```elixir
Polly.Polls.AccessLinkExport.generate(poll_id, actor,
  base_url: PollyWeb.Endpoint.url()
)
```

Suggested successful result:

```elixir
{:ok,
 %{
   filename: "annual-vote-access-links-2026-08-24.csv",
   content: csv_iodata,
   eligible_count: 24,
   active_count: 21,
   expired_count: 1,
   revoked_count: 1,
   not_issued_count: 1,
   missing_email_count: 2
 }}
```

The service must:

1. require an authenticated administrator actor;
2. load the poll through authorized Ash APIs;
3. load poll eligibilities with their members;
4. load relevant access grants without exposing tokens in errors;
5. resolve one status and at most one usable URL per eligible member;
6. encode all rows with a standards-compliant CSV encoder;
7. return iodata where practical to avoid unnecessary copies; and
8. perform no database writes.

The controller owns HTTP response construction. The LiveView owns explanatory
copy and the download action. Neither layer reimplements grant selection or CSV
encoding.

The `base_url` comes from trusted application configuration. Production must
require an HTTPS origin. Tests may inject `http://localhost` without changing
production URL behavior.

## Consistency and concurrency

Export is a read-only snapshot assembled at one point in time. Grant state may
change immediately after download—for example, an administrator may reissue a
link in another session.

The implementation should load the required data in one database transaction
when practical, but the CSV is not a permanent guarantee that every credential
will remain usable. Confirmation copy states:

> Link status is current when the file is generated. Revoking or reissuing a
> link afterward may make an exported URL invalid.

Export must never lock grants for distribution or prevent normal revoke and
reissue actions.

## Logging, telemetry, and audit trail

Application logs may record:

- export success or failure;
- poll ID;
- actor ID;
- row and status counts; and
- request ID.

They must not record:

- CSV content;
- private URLs;
- grant tokens or token fragments;
- member names or email addresses; or
- response bodies.

Exception reporting must avoid attaching export rows or encoded content as
metadata.

When the administrator audit trail is implemented, a successful export creates
one event:

```text
poll_access_links.exported
```

Safe event metadata includes counts and the poll ID. The audit record must not
contain the filename if it could later include sensitive input, member IDs,
names, emails, URLs, or tokens.

If audit creation is considered part of a successful download request, it is
recorded when generation succeeds. The audit event cannot prove that the
browser saved or distributed the file.

## Accessibility and responsive behavior

- The export control has an accessible label containing the poll title.
- Credential warnings are visible text and are associated with the confirmation
  action.
- Confirmation is keyboard operable and receives focus when opened.
- Status counts use text and do not rely on color alone.
- Success and failure states use the existing accessible flash region where
  applicable.
- On narrow screens, the export action and summary stack without hiding the
  security warning.

## Failure states

The interface distinguishes:

- no eligible members to export;
- poll not found or inaccessible;
- authenticated session expired before download;
- invalid or missing configured public base URL;
- inconsistent grant data that prevents safe resolution;
- CSV encoding failure; and
- unexpected database or response failure.

Failures render or redirect to a safe administrator page with an actionable
message that contains no member data, URL, or token. No partial file is stored
server-side.

## Testing requirements

### Domain tests

- exports the exact required header and column order;
- exports one row per eligible member and excludes non-eligible members;
- preserves names with commas, quotes, Unicode, and line breaks through valid
  CSV encoding;
- emits a blank email for a member without an email address;
- generates a canonical private URL for an active grant;
- reports `revoked` with a blank URL for a revoked latest grant;
- reports `expired` with a blank URL for an expired non-revoked grant;
- reports `not_issued` with a blank URL when no grant exists;
- chooses the newest usable grant if inconsistent history contains more than
  one candidate;
- sorts rows deterministically by name, email, and member ID;
- neutralizes spreadsheet-formula prefixes;
- handles an empty electorate without generating a misleading export;
- requires an authenticated actor;
- performs no database writes; and
- never includes revoked or expired token values anywhere in encoded output.

### Controller tests

- signed-out requests cannot download an export;
- authorized requests return `200` and the CSV content type;
- response disposition contains the expected safe filename;
- cache, referrer, and content-sniffing protection headers are present;
- response rows and URLs belong only to the requested poll;
- the configured application origin is used instead of a spoofed request host;
- inaccessible and unknown poll IDs return the expected safe response; and
- no token appears in redirects, flash messages, or error bodies.

### LiveView tests

- the access page shows the export action when eligibility exists;
- the empty electorate state does not offer an enabled download;
- confirmation explains that the file contains private credentials;
- confirmation shows accurate active, expired, revoked, not-issued, and
  missing-email counts;
- the download link targets the authenticated controller route; and
- export controls remain available for draft, open, closed, and archived polls
  as specified.

### Security tests

- formula-like member values are neutralized in spreadsheet cells;
- CSV content is absent from captured application logs;
- grant tokens are absent from failure messages and audit metadata;
- revoked and expired URLs are not reconstructable from the export; and
- production configuration rejects or warns on a non-HTTPS canonical origin.

## Rollout and operational considerations

1. Implement and test the read-only export service.
2. Add the authenticated controller route and secure response headers.
3. Add export counts, warning copy, and the download action to the access page.
4. Verify canonical production URL configuration before enabling the button.
5. Review organizational guidance for secure storage and distribution.
6. Add audit events when the audit trail feature is available.

The feature requires no schema migration. Existing eligibility and grant data
is sufficient.

Because exported credentials can outlive the browser session, administrators
should be instructed to regenerate the CSV after reissuing links and to delete
obsolete copies. Operational documentation should identify the approved
distribution channel and incident response for a leaked file.

## Acceptance criteria

The feature is complete when an authenticated administrator can confirm and
download a non-cached CSV containing every eligible member's name, optional
email, accurate link status, and full URL only for active grants; the file is
standards-compliant and spreadsheet-safe; no database state changes; and no
token, URL, or member data is persisted or exposed through logs, audit
metadata, error messages, or unauthenticated requests.

## Deferred enhancements

- Encrypted or password-protected export packages.
- Short-lived, one-time export download handles.
- Direct integration with an approved email or messaging provider.
- Per-member delivery status and retry tracking.
- Selecting a subset of eligible members for export.
- Separate exports for members missing email addresses.
- Administrator-configurable columns.
- `.xlsx` generation with protected cells.
- Scheduled exports or automatic secure delivery.
- Export watermarking and data-loss-prevention integration.
