# CSV Results Export — Technical Specification

## Status

Implemented.

## Summary

Allow an authenticated Polly administrator to download a poll's aggregate results as a CSV file. The first iteration exports one row per active poll option together with poll-level turnout context.

The export is an alternate representation of `Polly.Polls.Results.for_poll/1`; it must not independently reinterpret ballots or selections. It is available to administrators before and after public result publication and never includes member identities, access grants, private voting URLs, individual ballots, or timestamps that could be used to correlate a voter with a choice.

This is a small-to-medium complexity feature. Encoding CSV is straightforward, but the implementation must define stable result semantics, authorize a non-LiveView download route, prevent spreadsheet formula injection, remain correct for future multiple-choice and anonymous-choice polls, and avoid leaking unpublished results through caching or public endpoints.

## Goals

- Export the aggregate results already visible on the administrator results page.
- Include enough poll-level context to interpret option counts and percentages.
- Use a stable, documented column contract suitable for spreadsheet analysis.
- Preserve turnout as submitted ballots divided by eligible members.
- Support single-choice and future multiple-choice result semantics.
- Remain safe for future anonymous-choice polls.
- Generate the file on demand without retaining it in Polly.
- Record a safe administrator audit event for successful exports.

## Non-goals

- Exporting one row per ballot or selection.
- Exporting member names, emails, eligibility, participation, or access links.
- Exporting a voter-to-choice association.
- Combining multiple polls in one file.
- Scheduled or emailed exports.
- Export history or stored downloadable files.
- `.xlsx`, `.ods`, PDF, or chart-image generation.
- Importing edited results back into Polly.
- Applying tie-breaking, seat allocation, quorum, or election-certification rules.
- Proving that published results are cryptographically complete or untampered.

## Privacy boundary

The first iteration is deliberately aggregate-only. It may answer:

- how many eligible members the poll had;
- how many ballots were submitted;
- how many ballots selected each option; and
- the resulting turnout and per-option percentages.

It must not answer:

- which member selected an option;
- which options appeared together on a multiple-choice ballot;
- when an individual ballot was submitted;
- which access grant submitted a ballot; or
- whether a named eligible member participated.

This boundary applies to identified and anonymous-choice polls. A result export must never become a hidden linkage around the anonymous-choices design.

Aggregate results can still permit inference in very small electorates. The download confirmation should warn administrators that result files may be sensitive even though they contain no direct member identifiers.

## Availability and lifecycle

Authenticated administrators may export results for open and closed polls regardless of whether results have been published to members.

- **Open:** the file is a point-in-time snapshot and may change as ballots arrive.
- **Closed, unpublished:** the file contains final aggregate results that remain private to administrators.
- **Closed, published:** the file contains the same aggregate result state available to authorized members.

Draft polls have no valid ballot results. The results page should disable the export action while a poll is in draft and explain that the poll must open before results can be exported.

Archived closed polls remain exportable if poll archiving is implemented. Archiving changes administrative visibility, not result history or authorization.

An open poll export must be labelled as provisional in both the UI and CSV contract. Exporting does not close the poll or freeze its results.

## Source of truth

Add a focused service such as:

```elixir
Polly.Polls.ResultExport.generate(poll_id, actor: actor)
```

The service loads the authorized poll and builds its values from `Polly.Polls.Results.for_poll/1`. It must not duplicate result queries in the controller or LiveView.

The existing result projection remains authoritative for:

- option selection counts;
- ballot count;
- eligible-member count;
- turnout percentage;
- per-option percentage;
- rank; and
- leading or tied option state.

If future result modes require different denominators, the result projection must expose that meaning explicitly before the export contract is extended.

## CSV contract

### Format

- Media type: `text/csv; charset=utf-8`.
- Encoding: UTF-8.
- Delimiter: comma.
- Line ending: CRLF.
- Header row: always present.
- Quoting: RFC 4180-compatible.
- Encoder: the existing `NimbleCSV` dependency or another already-adopted standards-compliant encoder.
- Percentage values: decimal numbers rounded to one decimal place without a `%` character.
- Timestamps: ISO 8601 UTC strings.
- Boolean values: lowercase `true` or `false`.

Rows must not be assembled manually with `Enum.join/2`.

### Columns

Columns appear in this exact order:

```csv
poll_id,poll_title,poll_status,result_state,selection_mode,minimum_selections,maximum_selections,eligible_members,ballots_submitted,turnout_percentage,total_selections,option_position,option_label,selection_count,percentage_of_ballots,rank,leading,exported_at
```

`poll_id`:

- stable poll UUID;
- useful for joining exports without relying on a mutable title.

`poll_title`:

- title at export time;
- neutralized for spreadsheet formula safety.

`poll_status`:

- `open` or `closed` in the first iteration.

`result_state`:

- `provisional` when the poll is open;
- `final_unpublished` when closed and not published; or
- `final_published` when closed and published.

`selection_mode`:

- currently `single`;
- future values such as `multiple` use the poll's persisted mode.

`minimum_selections` and `maximum_selections`:

- both `1` for existing single-choice polls;
- populated from poll configuration after configurable multiple choice is implemented;
- until those attributes exist, the exporter emits `1` for both values.

`eligible_members`:

- number of eligibility records in the poll snapshot.

`ballots_submitted`:

- number of final submitted ballots;
- remains the turnout numerator even when one ballot has multiple selections.

`turnout_percentage`:

- `ballots_submitted / eligible_members * 100`;
- `0.0` when there are no eligible members.

`total_selections`:

- sum of all option selection counts;
- equal to ballot count for single-choice polls;
- may exceed ballot count for multiple-choice polls.

`option_position`:

- the option's configured position;
- provides a stable tie-breaker and reconstructs ballot order.

`option_label`:

- option label at export time;
- neutralized for spreadsheet formula safety.

`selection_count`:

- number of submitted ballots containing that option;
- one ballot can contribute at most one count to a given option.

`percentage_of_ballots`:

- `selection_count / ballots_submitted * 100`;
- `0.0` when there are no ballots;
- equivalent to vote share for single-choice polls;
- represents support rate for multiple-choice polls, where column values may total more than 100%.

`rank`:

- competition rank by selection count;
- blank when no ballots have been submitted.

`leading`:

- `true` when the option is tied for the highest non-zero selection count;
- `false` when it is not leading or when there are no ballots;
- does not certify the option as an election winner.

`exported_at`:

- one timestamp captured once for the entire export;
- repeated on each row so detached rows retain snapshot context.

### Example

```csv
poll_id,poll_title,poll_status,result_state,selection_mode,minimum_selections,maximum_selections,eligible_members,ballots_submitted,turnout_percentage,total_selections,option_position,option_label,selection_count,percentage_of_ballots,rank,leading,exported_at
cbc0064d-2220-4dff-93a5-98e4f8483e8d,Board Election,closed,final_published,single,1,1,20,16,80.0,16,1,Jamie Rivera,9,56.3,1,true,2026-08-26T18:30:00Z
cbc0064d-2220-4dff-93a5-98e4f8483e8d,Board Election,closed,final_published,single,1,1,20,16,80.0,16,2,Morgan Lee,7,43.8,2,false,2026-08-26T18:30:00Z
```

## Ordering and determinism

Rows are ordered by:

1. rank ascending, with blank ranks last;
2. selection count descending;
3. option position ascending; and
4. option ID as a stable final tie-breaker.

All rows use one captured `exported_at` value and one result projection. The service must not rerun counts independently for each option because an open poll could otherwise produce internally inconsistent rows.

Aside from `exported_at`, two exports of an unchanged poll should contain the same values and ordering.

## Empty results

An open or closed poll with active options but zero ballots produces one row per option with:

- `ballots_submitted` set to `0`;
- `turnout_percentage` set to `0.0`;
- `total_selections` set to `0`;
- `selection_count` set to `0`;
- `percentage_of_ballots` set to `0.0`;
- blank `rank`; and
- `leading` set to `false`.

This is preferable to a header-only file because it retains the configured choices and clearly represents a zero-response result.

A poll with no active options cannot open under current rules. If inconsistent historical data has no active options, the service returns a safe `:no_options` error rather than producing a misleading header-only export.

## Spreadsheet formula safety

CSV quoting does not prevent spreadsheet formula execution. Before encoding, any text cell beginning with `=`, `+`, `-`, or `@` after leading whitespace must be neutralized with a documented spreadsheet-safe prefix such as a single quote.

At minimum this applies to:

- `poll_title`;
- `option_label`; and
- any future free-text column.

The transformation affects only the exported representation and never updates persisted poll data.

## Filename and response headers

Use the poll slug and export date:

```text
<poll-slug>-results-YYYY-MM-DD.csv
```

Example:

```text
board-election-results-2026-08-26.csv
```

The server generates the filename; browser parameters cannot override it.

The response includes:

```text
Content-Type: text/csv; charset=utf-8
Content-Disposition: attachment; filename="<generated-name>"
Cache-Control: private, no-store, max-age=0
Pragma: no-cache
X-Content-Type-Options: nosniff
```

The response must not be cached by a shared proxy or browser history cache.

## HTTP and authorization design

Use an authenticated controller endpoint:

```text
GET /admin/polls/:poll_id/results.csv
```

A controller route is preferable to returning file contents from a LiveView event. The route belongs to the browser pipeline and requires an explicit authenticated administrator plug; an authenticated LiveView session does not automatically protect controller routes.

The controller:

1. obtains the authenticated actor from the session-loaded connection;
2. passes the poll ID and actor to `ResultExport.generate/2`;
3. receives CSV iodata and the server-generated filename;
4. applies private download headers; and
5. sends the response without logging its body.

Authorization must be enforced when the service loads the poll. The service must not use `authorize?: false` at its public boundary merely because the caller is an administrator UI.

Expected error behavior:

- unauthenticated: redirect to sign-in without exposing whether the poll exists;
- unauthorized or unknown poll: return the application's standard not-found/forbidden response;
- draft poll: return a safe unavailable response;
- no active options: return a safe unavailable response; and
- unexpected generation failure: log only safe identifiers and return a generic error.

No CSV data belongs in query parameters, flash messages, logs, exception metadata, or telemetry attributes.

## Administrator workflow

Add an **Export results CSV** action to `/admin/polls/:id/results`.

The action is disabled for draft polls. For open and closed polls, selecting it opens a confirmation panel containing:

- poll title;
- provisional or final result state;
- eligible-member count;
- submitted-ballot count;
- turnout percentage;
- option count;
- a warning that aggregate results may still be sensitive for small electorates; and
- an explanation that the file contains no member identities or private links.

For open polls, the primary action says **Download provisional results**. For closed polls, it says **Download final results**.

The download uses a normal `href` to the controller endpoint and does not navigate the LiveView away from the results page. Stable DOM IDs should cover the export button, confirmation panel, cancellation action, and download link.

Exporting is read-only. It does not close or publish the poll and does not change result state.

## Audit trail

After successful generation, append one administrator event:

```text
poll.results_exported
```

Safe metadata includes:

- poll status;
- result state;
- option count;
- ballot count;
- eligible-member count; and
- whether the export was provisional or final.

Audit metadata must not include:

- encoded CSV contents;
- option labels;
- member or participant identifiers;
- ballot or selection IDs; or
- any access token or private URL.

The audit event and file generation need not share a database transaction because generation is read-only. Define “successful export” consistently: the first iteration records the event once generation completes and the response is constructed, while acknowledging that the server cannot prove the browser saved the file.

## Observability

Emit safe aggregate telemetry for:

- export generation count;
- success or failure;
- generation duration;
- row count; and
- provisional versus final state.

Logs and telemetry may include the poll ID and administrator actor ID under existing audit policy. They must not contain CSV rows, option labels, member data, ballots, selections, tokens, or URLs.

## Interaction with planned features

### Multiple-choice polls

The column contract is already compatible with configurable multiple choice:

- `total_selections` may exceed `ballots_submitted`;
- `selection_count` counts ballots supporting an option; and
- `percentage_of_ballots` is a support rate whose rows may total more than 100%.

The exporter must read limits from the poll once those attributes are implemented rather than maintaining separate assumptions.

### Anonymous choices

The aggregate export contract is valid for anonymous-choice polls because it reads only the aggregate result projection. It must not query participation records or attempt to enrich rows with voter data.

### Poll archiving

Archived closed polls remain exportable through their results page. Archival status may be added as a future column only through a versioned contract change.

### Public result pages

This endpoint remains administrator-only even after public result pages exist. A public CSV download would require separate authorization, privacy, caching, and abuse analysis.

## Testing strategy

### Service tests

- Emits the exact header and column order.
- Exports one row per active option.
- Uses the authoritative result projection values.
- Produces provisional, final-unpublished, and final-published states correctly.
- Represents zero ballots without division errors.
- Calculates total selections separately from ballot count.
- Orders leading, tied, and lower-ranked options deterministically.
- Uses one captured export timestamp across all rows.
- Quotes commas, quotes, Unicode, and line breaks correctly.
- Neutralizes spreadsheet formulas in titles and option labels.
- Produces a safe slug-derived filename.
- Rejects draft polls and inconsistent polls without options.
- Does not persist generated files.

### Controller tests

- Signed-out requests cannot download an export.
- Authenticated administrators receive CSV with the required headers.
- Unknown or unauthorized polls do not leak existence.
- Draft-poll downloads are rejected.
- Responses are attachments, private, non-cacheable, and `nosniff`.
- Response bodies are not written to captured logs.
- Successful downloads append a safe audit event.

### LiveView tests

- Draft polls show a disabled export action with explanatory copy.
- Open polls show a provisional-export confirmation.
- Closed polls show a final-export confirmation.
- Confirmation displays turnout and sensitivity guidance.
- Cancelling keeps the administrator on the results page.
- The final action points to the authenticated controller route.

### Privacy regression tests

- Headers and rows contain no member name, email, member ID, access-grant ID, token, private URL, ballot ID, or selection ID.
- Anonymous-choice exports use the same aggregate contract.
- Multiple-choice exports reveal no combination of selections from an individual ballot.
- Audit metadata and telemetry contain no result rows or option labels.

## Rollout plan

1. Implement and test `Polly.Polls.ResultExport` against the current result projection.
2. Add the authenticated controller route and private response headers.
3. Add the results-page confirmation and download action.
4. Add `poll.results_exported` to the audit event vocabulary and presentation.
5. Verify output manually in supported spreadsheet applications.
6. Verify formula neutralization and Unicode handling.
7. Re-run privacy tests when anonymous choices or multiple-choice polls are introduced.

The first iteration generates exports synchronously because the result is compact aggregate data with one row per option. If option counts or report complexity grow enough to require background generation, that future design must use short-lived authorized download handles and explicit retention rules rather than attaching CSV data to Oban arguments.

## Acceptance criteria

- An authenticated administrator can download an open or closed poll's aggregate results as CSV.
- Draft polls cannot export results.
- The CSV uses the documented columns, encoding, escaping, ordering, and filename.
- Counts and percentages match the administrator results screen at generation time.
- Open-poll files are clearly marked provisional.
- Closed files distinguish unpublished and published final results.
- Zero-ballot polls export valid zero-valued option rows.
- The export contains no voter identity, participation, ballot-level combination, access credential, or private URL.
- Spreadsheet formula injection is neutralized.
- The response is private, non-cacheable, and generated on demand without file retention.
- A safe audit event records successful generation.
- The contract remains valid for future multiple-choice and anonymous-choice polls.

## Open decisions

1. Should `poll_id` be included for easier joining, or omitted to make the file friendlier for non-technical administrators?
2. Should result rows use rank order, configured option order, or offer both as separate export formats?
3. Should published exports include `results_published_at` as an additional versioned column?
4. Should small-electorate exports require an extra warning threshold configured per installation?
5. Should future public result pages offer a separate public aggregate CSV endpoint?

## Related documentation

- [Multiple-choice polls specification](multiple-choice-polls-spec.md)
- [Anonymous choices specification](anonymous-choices-spec.md)
- [Poll archiving specification](poll-archiving-spec.md)
- [Administrator audit trail specification](admin-audit-trail-spec.md)
