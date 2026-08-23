# CSV member upload feature specification

## Summary

Add an authenticated administrator workflow for importing many members from a
CSV file. The workflow must parse and validate the entire file, show a preview,
and require explicit confirmation before writing any member records.

The first release is an additive roster import. It creates new active members
and leaves existing members unchanged. It does not remove or deactivate members,
change a poll electorate, or issue poll access grants.

## Goals

- Reduce the effort required to create a member roster.
- Give administrators a clear preview of what will and will not be imported.
- Make re-uploading the same file safe and idempotent.
- Prevent partial imports and ambiguous duplicate members.
- Keep uploaded personally identifiable information private and short-lived.

## Non-goals

- Selecting or modifying a poll electorate.
- Issuing, exporting, or emailing voting links.
- Updating, deactivating, or deleting existing members.
- Importing ballots, poll options, or historical data.
- Supporting spreadsheet formats such as `.xlsx` or `.ods`.
- Retaining the original CSV after the import request finishes.

## User stories

- As an administrator, I can download or view the required CSV format.
- As an administrator, I can upload a roster and review valid, existing, and
  invalid rows before anything is written.
- As an administrator, I can correct a rejected file and upload it again.
- As an administrator, I can confirm a valid preview and create all new members
  in one operation.
- As an administrator, I can safely upload the same file again without creating
  duplicate members.

## CSV contract

### File requirements

- File extension: `.csv`.
- Encoding: UTF-8; an optional UTF-8 byte-order mark is accepted.
- Maximum file size: 2 MB.
- Maximum data rows: 5,000, excluding the header.
- Delimiter: comma.
- Quoted fields, embedded commas, and CRLF or LF line endings must be supported.
- Empty lines are ignored.
- A standards-compliant CSV parser must be used; rows must never be parsed with
  `String.split/2`.

### Headers

The required headers are:

```csv
name,email
```

Header matching is case-insensitive and ignores surrounding whitespace. Column
order does not matter. Missing required headers and unknown headers reject the
file. Strict headers prevent silent mistakes caused by misspelled column names.

### Field rules

`name`:

- Required after trimming whitespace.
- Between 1 and 160 characters, matching the `Member` resource constraint.
- Preserves internal spacing and letter case after surrounding whitespace is
  removed.

`email`:

- Required for CSV imports, even though manually created members may omit it.
- Trimmed and converted to lowercase before comparison and storage.
- Must satisfy the `Member` email format and 320-character limit.
- Acts as the stable identity used to make imports idempotent.

All imported members are created with `active: true`.

Example:

```csv
name,email
Jamie Rivera,jamie.rivera@example.com
"Morgan Lee, Jr.",morgan.lee@example.com
```

## Duplicate handling

Email comparison is case-insensitive after trimming.

- If the same normalized email appears more than once in the uploaded file,
  every occurrence is marked invalid and the import cannot be confirmed.
- If an email already belongs to an existing member, the row is classified as
  `existing` and no change is made.
- If an existing email has a different name, the preview displays both names
  and warns that the existing member will remain unchanged.
- Duplicate names with different email addresses are allowed because names are
  not stable identities.

Before implementation, existing member emails must be audited for
case-insensitive duplicates. The `Member` resource and database should then
enforce a unique normalized email identity while continuing to permit multiple
members with no email address.

## Administrator workflow

The feature lives at `/admin/members/import` and is linked from the member list.
It belongs to the existing authenticated administrator LiveView session.

### 1. Upload

The page explains the required columns and provides a small example. The
administrator selects or drops one CSV file and chooses **Preview import**.

### 2. Preview

The server parses the complete file and displays:

- total data rows;
- number of new members;
- number of existing members that will be skipped;
- number of invalid rows;
- a row table containing the CSV row number, name, email, classification, and
  validation messages.

No database writes occur during preview. The preview is held only in LiveView
state and is replaced when another file is uploaded.

If any row is invalid, **Import members** is disabled. The administrator must
fix the source file and upload it again. Valid rows are not imported separately.

### 3. Confirm

When every row is valid, the administrator explicitly confirms the import. The
confirmation copy states how many members will be created and how many existing
members will be skipped.

The server revalidates the preview against current database state and performs
the import in one transaction. This prevents the preview from becoming unsafe
if another administrator creates a member with the same email before
confirmation.

### 4. Result

On success, the administrator returns to `/admin/members` with a summary such
as “42 members imported; 3 existing members skipped.” The member list is
refreshed and includes the new members.

On failure, no members from the file are created. The preview remains visible
with an actionable error, allowing the administrator to retry.

## Domain design

CSV parsing and the LiveView must not create members row by row directly.
Introduce a member import boundary with two operations conceptually equivalent
to:

```elixir
Polly.Members.MemberImport.preview(csv_contents)
Polly.Members.MemberImport.commit(preview, actor)
```

`preview/1` returns a structured result rather than raising for ordinary row
errors. Each row has a stable row number and one of these classifications:

- `:new`
- `:existing`
- `:invalid`

`commit/2` must:

1. require an authenticated administrator actor;
2. reject a preview that contains invalid rows;
3. recheck normalized emails against the database;
4. create all new members inside one repository transaction;
5. roll back the entire import if any creation fails; and
6. return created and skipped counts.

The import service may accept parsed row data internally, but it must not trust
classification flags or member IDs supplied by browser parameters.

## Concurrency

The database email identity is the final concurrency guard. If two imports with
the same new email are confirmed concurrently, at most one member is created.
The losing import should reclassify that email as existing when possible; any
other failure rolls back its entire transaction and returns a retryable error.

## Security and privacy

- The route and all import actions require an authenticated administrator.
- Uploaded contents, member names, and email addresses must not be written to
  application logs.
- Parser and validation errors must not echo raw file contents.
- Uploaded files are temporary and must not be copied to durable application
  storage.
- Rendered cell values rely on HEEx escaping and must never be treated as HTML.
- Spreadsheet formula prefixes (`=`, `+`, `-`, and `@`) are treated as ordinary
  text. Any future CSV export must escape them separately.
- File size and row limits are enforced before committing data.

## Accessibility and responsive behavior

- The file input has a visible label and concise help text.
- Upload, preview, validation, and import status changes are announced through
  an `aria-live` region.
- Errors identify both the row number and field.
- Preview classifications do not rely on color alone.
- The preview table remains usable on narrow screens through horizontal
  scrolling or a stacked row presentation.
- All actions are keyboard accessible and retain visible focus indicators.

## Failure states

The interface distinguishes:

- unsupported file type;
- oversized file;
- invalid UTF-8;
- malformed CSV;
- missing or unknown headers;
- too many rows;
- duplicate emails within the file;
- invalid names or emails;
- a file containing only headers or empty rows;
- concurrent database conflicts; and
- an unexpected transactional import failure.

## Testing requirements

### Parser and preview tests

- accepts valid UTF-8 CSV with either LF or CRLF line endings;
- accepts quoted names containing commas and an optional UTF-8 BOM;
- normalizes header whitespace and case;
- trims names and lowercases emails;
- rejects malformed CSV, invalid UTF-8, missing headers, and unknown headers;
- rejects files over the row limit;
- reports original CSV row numbers after ignoring empty lines;
- rejects duplicate normalized emails within one file;
- classifies existing emails without updating their member records; and
- allows duplicate names when emails differ.

### Domain and transaction tests

- creates every new member and skips every existing member;
- re-uploading the same file creates no duplicates;
- invalid rows prevent all writes;
- a member creation failure rolls back all rows;
- concurrent imports create at most one member per normalized email; and
- anonymous callers cannot commit an import.

### LiveView tests

- signed-out visitors are redirected to sign in;
- the member list links to the import page;
- a valid upload renders the preview counts and row classifications;
- an invalid preview disables confirmation and shows row-level errors;
- replacing a file replaces the previous preview;
- confirming a valid preview redirects with the correct summary; and
- imported members appear in the member list.

## Acceptance criteria

The feature is complete when an authenticated administrator can upload a valid
CSV containing up to 5,000 members, preview every proposed change, and confirm
one atomic import; existing members are skipped by normalized email, invalid
files write nothing, repeated uploads create no duplicates, and the original
file is not retained.

## Deferred enhancements

- An explicit update-existing-members mode.
- Deactivation or roster synchronization from a CSV.
- Partial import of only valid rows.
- Downloadable error reports.
- Import history and rollback tooling.
- Mapping arbitrary source column names.
- Spreadsheet uploads.
- Adding imported members directly to a draft poll electorate.
