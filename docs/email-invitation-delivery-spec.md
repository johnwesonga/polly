# Email Invitation Delivery — Technical Specification

## Status

Implemented, including the operational-hardening iteration.

## Summary

Polly administrators can currently issue private access grants and manually distribute their voting URLs. This feature allows an administrator to email each eligible member their private voting link directly from Polly.

The first iteration will:

- send one individualized email per recipient;
- operate only on open polls;
- use an existing, active, unexpired access grant;
- queue delivery in durable background jobs;
- show queued, sent, failed, and skipped outcomes to administrators;
- support an explicit per-member resend; and
- record the initiating administrative action without exposing private URLs or tokens in the audit trail.

Production delivery will use [Resend](https://resend.com/) through Swoosh's built-in `Swoosh.Adapters.Resend` adapter and the application's existing `Req` API client.

In this specification, **sent** means the configured email adapter or provider accepted the message. It does not prove that the message reached the recipient's inbox, was opened, or was read.

## Motivation

Private voting currently requires administrators to export, copy, or otherwise distribute access links themselves. That process is repetitive and creates avoidable risks:

- a link can be sent to the wrong person;
- a member can receive another member's link;
- the administrator has no central view of which invitations were attempted;
- manual distribution can leak bearer tokens into documents or chat systems; and
- large electorates are time-consuming to handle.

Email invitation delivery centralizes distribution while preserving the existing access-grant model.

## Complexity assessment

This is a medium-to-high complexity feature. Rendering and sending an email is straightforward; safely delivering bearer credentials is not. The implementation must account for durable jobs, retries, duplicate sends, concurrent administrators, poll and grant changes while work is queued, provider configuration, privacy, and operational visibility.

The feature should therefore not be implemented as a loop in a LiveView process or as fire-and-forget `Task` processes.

## Goals

- Allow an administrator to preview invitation readiness for a poll.
- Send invitations to all ready recipients in one administrative operation.
- Send or resend an invitation to one member explicitly.
- Generate every private voting URL from the recipient's own access grant.
- Avoid duplicate initial invitations when requests are retried or submitted concurrently.
- Retry transient email-provider failures without duplicating successful sends.
- Preserve a useful delivery history for support and administration.
- Prevent tokens and private URLs from entering audit metadata, job arguments, logs, or telemetry.
- Use Polly's existing `Polly.Mailer` and Swoosh configuration.

## Non-goals for the first iteration

- Scheduled invitation delivery.
- Automatic reminder campaigns.
- Rich template editing by administrators.
- Localization.
- Open and click tracking.
- Provider webhook processing for bounces, complaints, or confirmed delivery.
- Automatic access-grant issuance, reissue, or revocation.
- Emailing CSV attachments containing access links.
- Sending invitations for draft or closed polls.
- Marketing-email subscription management.

## Terminology

- **Ready recipient**: an eligible, active member with an email address and a usable access grant who has not already submitted a ballot.
- **Usable grant**: an access grant that exists, has not been revoked, and has not expired.
- **Initial invitation**: the first successful or queued invitation for a particular access grant.
- **Resend**: a new, explicit delivery attempt requested after an initial invitation has already been queued or sent.
- **Accepted**: Swoosh's configured adapter returned success. The administration UI may label this state “Sent,” with explanatory text.
- **Skipped**: no job was created because the recipient was not ready.
- **Cancelled**: a queued delivery became unsafe or invalid before it was sent.

## User stories

### Bulk invitation

As an administrator, I can review how many members are ready, skipped, or already invited before confirming a bulk send.

As an administrator, I can enqueue invitations without waiting for the email provider to process the whole electorate in my browser request.

As an administrator, I can see the latest delivery state for each eligible member.

### Individual invitation

As an administrator, I can send an initial invitation to one ready member.

As an administrator, I can explicitly resend a member's invitation when they report that they did not receive it.

### Support and safety

As an administrator, I can see a safe failure category and retry a failed invitation without viewing the private token.

As a member, I receive only my own private voting link in a message addressed only to me.

## Eligibility and send rules

An invitation may be queued only when all of the following are true:

1. The poll status is `open`.
2. The member is part of the poll's electorate.
3. The member is active.
4. The member has a non-empty, valid email address.
5. The member has a usable access grant for the poll.
6. The member has not submitted a ballot for the poll.
7. For an initial invitation, no initial delivery already exists for the same access grant.

The service must not issue or reissue a grant as a side effect of sending email. An administrator must resolve a missing, revoked, or expired grant through the existing access-management workflow.

The first iteration must not email invitations while a poll is in draft. This avoids distributing a link that cannot yet be used and gives the administrator a clear sequence: configure the poll, open it, then send invitations.

If the poll closes, the grant is revoked or expires, the member is deactivated, the email address is removed, or a ballot is submitted after enqueueing but before execution, the worker must cancel the delivery without sending it.

## Readiness categories

The preview service classifies every electorate member into exactly one category:

| Category | Meaning | Bulk action |
| --- | --- | --- |
| Ready | All send rules pass and no initial invitation exists | Queue invitation |
| Already invited | An initial invitation exists for the current grant | Skip |
| Already voted | A ballot exists for the member and poll | Skip |
| Missing email | No usable member email address exists | Skip |
| Inactive member | The member is inactive | Skip |
| Missing grant | No access grant exists | Skip |
| Revoked grant | The current grant is revoked | Skip |
| Expired grant | The current grant has expired | Skip |

The confirmation screen displays aggregate counts. It must not imply that skipped members have been invited.

## Administrator workflow

### Poll access page

Extend `/admin/polls/:id/access` with an **Email invitations** section.

The section displays:

- the number of ready recipients;
- counts for each skipped category;
- the latest delivery state for each electorate member;
- the timestamp of the latest accepted attempt;
- a bulk **Send email invitations** button; and
- a per-member **Send**, **Retry**, or **Resend** action when applicable.

The bulk button is disabled when the poll is not open or no recipients are ready.

### Bulk confirmation

Selecting **Send email invitations** opens a confirmation view or modal showing:

- the poll title;
- the number of messages that will be queued;
- the number of members that will be skipped;
- a breakdown of skip reasons; and
- a warning that each message contains a private voting link.

Confirmation submits one idempotent bulk operation. The browser receives a prompt response after jobs have been persisted; it does not wait for delivery.

### Per-member resend

An initial send may be queued from the member row when no initial delivery exists. Once an initial delivery exists, sending again is an explicit resend and requires confirmation.

A resend creates a new delivery record. It never mutates an accepted historical attempt and never changes the access grant. If the grant has been reissued, the new grant is treated as a new initial invitation.

### Status presentation

The UI uses these labels:

- Queued
- Sending
- Sent
- Failed
- Cancelled

“Sent” includes help text explaining that the email provider accepted the message and that inbox delivery is not confirmed.

The UI must update after enqueueing and may use LiveView polling or PubSub notifications. PubSub is preferable but not required for the first iteration.

## Email content

Each recipient receives a separate multipart email containing plain-text and HTML bodies.

### Required fields

- `To`: the individual member's name and email address.
- `From`: an application-configured sender name and email address.
- `Reply-To`: optional, application-configured support address.
- Subject: `Voting is open: <poll title>`.

### Required body content

- the member's name;
- the poll title;
- a concise invitation to vote;
- the member's private voting URL;
- notice that the link is personal and must not be forwarded;
- notice that a submitted vote is final, if that is still Polly's ballot behavior; and
- a plain-text fallback containing the same essential information.

The access token or URL must never appear in the subject, custom headers, provider tags, metadata, or message identifiers.

The template should avoid including unnecessary electorate or poll information. The poll description may be included only if administrators already understand it to be suitable for recipients.

## URL generation

The worker constructs the voting URL in memory from:

- the configured canonical public application origin;
- the poll route; and
- the access grant's raw token or existing safe URL-building interface.

The origin must come from trusted endpoint/runtime configuration, never from the incoming request's `Host` header. Production must use HTTPS.

The full URL must not be persisted in the delivery table, Oban job arguments, audit metadata, logs, exception context, or telemetry attributes.

## Proposed data model

Add a `Polly.Polls.InvitationDelivery` Ash resource backed by an `invitation_deliveries` table.

Suggested attributes:

| Attribute | Type | Notes |
| --- | --- | --- |
| `id` | UUID | Primary key |
| `poll_id` | UUID | Poll relationship and query boundary |
| `member_id` | UUID | Recipient relationship |
| `access_grant_id` | UUID | Grant used to build the private URL |
| `requested_by_id` | UUID, nullable | Authenticated administrator when available |
| `operation_id` | UUID | Groups deliveries created by one bulk or individual request |
| `kind` | enum | `initial` or `resend` |
| `dedupe_key` | string | Unique idempotency key |
| `status` | enum | `queued`, `sending`, `accepted`, `failed`, or `cancelled` |
| `recipient_email` | string, sensitive | Normalized address selected at enqueue time |
| `attempt_count` | integer | Starts at zero |
| `provider_message_id` | string, nullable, sensitive | Resend email ID returned after acceptance |
| `last_error_code` | string, nullable | Safe internal category, not a provider response dump |
| `requested_at` | UTC datetime | Enqueue time |
| `accepted_at` | UTC datetime, nullable | Adapter/provider acceptance time |
| `failed_at` | UTC datetime, nullable | Terminal failure time |
| `cancelled_at` | UTC datetime, nullable | Safety cancellation time |
| `inserted_at` | UTC datetime | Standard timestamp |
| `updated_at` | UTC datetime | Standard timestamp |

`recipient_email` is a snapshot so an address cannot silently change between administrator confirmation and job execution. It is sensitive personal data and must be redacted from inspection output and logs. A later retention task should redact this snapshot after the operational support window while retaining non-identifying delivery counts.

### Relationships and deletion behavior

- `belongs_to :poll`
- `belongs_to :member`
- `belongs_to :access_grant`
- optional relationship to the administrator/member identity used by the current authentication model

Poll, member, and grant deletion should not silently erase audit-relevant delivery history. If Polly later supports physical deletion, relationships should become nullable or records should be anonymized according to the application's retention policy.

### Idempotency constraints

For initial invitations, use a deterministic unique key:

```text
initial:<access_grant_id>
```

For an explicit resend, use:

```text
resend:<operation_id>:<access_grant_id>
```

A unique database identity on `dedupe_key` prevents two administrators, double-clicks, LiveView retries, or job-enqueue retries from creating duplicate initial deliveries. A reissued grant has a new ID and may therefore receive a new initial invitation.

Pass the same `dedupe_key` to Resend as the provider `idempotency_key`. This supplies a second layer of protection if a request reaches Resend but Polly loses the response and retries the job. Resend currently retains idempotency keys for 24 hours, so Polly's database constraint remains the durable source of truth.

## Application services

Add a focused delivery context, for example `Polly.Polls.Invitations`, rather than placing orchestration in the LiveView.

### Preview

```elixir
Invitations.preview(poll_id, actor: actor)
```

The preview result contains:

- the poll;
- aggregate category counts;
- recipient classifications needed by the UI; and
- whether bulk sending is currently allowed.

The authoritative classification is recalculated during enqueue; the preview is advisory and may become stale.

### Bulk enqueue

```elixir
Invitations.enqueue_bulk(poll_id, actor: actor, operation_id: operation_id)
```

The operation:

1. verifies administrator authorization;
2. reloads and locks or consistently queries the poll and recipient state;
3. reclassifies recipients;
4. inserts delivery records for ready recipients;
5. inserts one background job per new delivery;
6. appends one aggregate administrative audit event; and
7. returns queued and skipped counts.

Delivery rows, jobs, and the audit event must commit atomically. If the transaction fails, none of them should remain.

### Individual enqueue

```elixir
Invitations.enqueue_one(access_grant_id,
  actor: actor,
  kind: :initial | :resend,
  operation_id: operation_id
)
```

The same domain validations apply. A resend must be explicit; the service must not silently convert a duplicate initial request into a resend.

## Background processing

### Recommendation

Use Oban for durable background work. Polly currently uses SQLite, and current Oban releases provide a SQLite engine named `Oban.Engines.Lite`. The exact dependency version must be selected against Polly's Elixir, SQLite, Ash, and Ecto versions during implementation. The implementation also requires Oban configuration, its migration, and a supervised Oban instance.

For a single-node Polly deployment, SQLite-backed jobs are an appropriate initial architecture. A multi-node or high-throughput deployment should reassess the database and queue topology.

Do not use a LiveView process, unsupervised process, or fire-and-forget task for delivery. Losing the web process must not lose accepted work.

### Job shape

Create one job per delivery record. The job arguments contain only:

```elixir
%{"delivery_id" => delivery.id}
```

They must not contain an email address, member name, access token, or voting URL.

### Worker execution

The worker:

1. loads the delivery, poll, member, and access grant;
2. exits successfully if the delivery is already accepted or cancelled;
3. revalidates the poll, member, grant, ballot, and recipient email snapshot;
4. atomically transitions the delivery from `queued` to `sending`;
5. constructs the private URL in memory;
6. builds and sends the Swoosh email;
7. records provider acceptance and `accepted_at`; or
8. records a safe error category and requests a retry when appropriate.

If validation no longer passes, the worker transitions the delivery to `cancelled` and does not send.

### Retries

Classify failures into:

- **Transient**: timeouts, connection failures, provider rate limits, and server-side provider errors. Retry with exponential backoff and bounded attempts.
- **Permanent**: malformed recipient address, rejected credentials, invalid sender configuration, or other non-retryable provider response. Mark failed without repeated attempts.
- **State cancellation**: the poll/grant/member/ballot state changed. Mark cancelled and do not retry.

The exact HTTP/provider response must not be copied into `last_error_code`. Use safe categories such as `timeout`, `rate_limited`, `provider_unavailable`, `recipient_rejected`, and `configuration_error`.

An exhausted job must leave its delivery in `failed`, not indefinitely in `sending`.

### Concurrency

Use a bounded queue concurrency appropriate to the provider's rate limit. One recipient must never be placed in another recipient's `To`, `Cc`, or `Bcc` field.

The database dedupe identity is the final defense against duplicate initial sends. Job uniqueness may be added as a second defense but must not replace the database constraint.

## Resend and Swoosh integration

Continue using `Polly.Mailer` and configure it with `Swoosh.Adapters.Resend`. Polly's locked Swoosh version already contains this adapter, and the project already includes `Req`, so the separate community `resend` dependency is not needed.

Swoosh's delivery result reflects adapter behavior, so Polly records Resend API success as `accepted`, not as confirmed inbox delivery. Persist Resend's returned email ID when available as a sensitive operational identifier. It may be used for support or future webhook correlation but must not be shown publicly or placed in audit metadata.

Required production configuration:

- `Swoosh.Adapters.Resend` as the production adapter;
- `RESEND_API_KEY` supplied through runtime secrets;
- sender name and address;
- optional reply-to address;
- the canonical public application URL; and
- `Swoosh.ApiClient.Req`, which is already configured for production.

The intended runtime configuration is equivalent to:

```elixir
config :polly, Polly.Mailer,
  adapter: Swoosh.Adapters.Resend,
  api_key: System.fetch_env!("RESEND_API_KEY")
```

The API key may be loaded locally from the ignored `.envrc` file. Hosted and production environments must set `RESEND_API_KEY` in their secret manager or deployment environment; `.envrc` is not a deployment mechanism and must remain untracked. The API key must never be included in application logs, error messages, committed configuration, job arguments, or audit metadata.

Development may continue using the local mailbox adapter. Tests must use Swoosh's test facilities and must not make real network requests.

Before unrestricted production delivery, Polly's sending domain must be verified in Resend. The operator must publish the DNS records supplied by Resend and should configure an appropriate DMARC policy.

Configuration should be validated before enabling the UI action. A missing sender or provider configuration should produce a clear administrator-facing unavailable state rather than queueing messages that cannot be sent.

## Audit trail

Bulk enqueue appends one administrative event, for example:

```text
poll.invitations_enqueued
```

Safe metadata may include:

- `operation_id`;
- queued count;
- total skipped count;
- counts by skip reason; and
- request kind (`bulk`, `individual`, or `resend`).

It must not include:

- member names;
- email addresses;
- access tokens;
- private URLs;
- provider payloads; or
- a recipient list.

Individual sends and resends use the same event with a queued count of one and the relevant request kind.

Provider attempts and automated worker outcomes are operational events, not administrator actions. They belong in delivery records, metrics, and sanitized telemetry rather than as a new admin audit event for every retry.

## Authorization

- Only authenticated administrators who can manage the poll's access grants may preview or enqueue invitations.
- The LiveView must not be the sole authorization boundary; the service and Ash actions must enforce authorization.
- Workers operate as a trusted system actor only for the previously authorized delivery record.
- Read access to delivery records must follow the same administrative boundary as access-grant management.

## Security and privacy

Private voting links are bearer credentials. Anyone who obtains a usable link may exercise the access it represents.

The implementation must therefore:

- send exactly one private link per message;
- never use bulk `Bcc` distribution;
- never expose another member's link in previews or status tables;
- keep tokens, links, and emails out of job arguments and audit metadata;
- configure log and exception redaction for sensitive resource attributes;
- avoid placing secrets in telemetry measurements or tags;
- construct URLs only at the final delivery boundary;
- use HTTPS in production;
- avoid leaking the link through remote images or analytics query parameters; and
- document that the email provider will necessarily process message contents containing the private URL.

The provider's retention, data-processing terms, regional processing, and access controls must be reviewed before production use.

## Observability

Expose aggregate operational metrics without recipient identifiers:

- jobs queued;
- messages accepted;
- messages failed;
- messages cancelled;
- retry count;
- queue latency; and
- provider request latency.

Logs should identify a delivery by delivery ID and operation ID. They must not contain the recipient email, member name, token, or URL.

Administrator-visible errors should be actionable but sanitized, for example “Email provider authentication is not configured” or “The provider temporarily rejected this request.”

### Oban Web dashboard

The next operational-hardening iteration will add the open-source `oban_web` package and mount its dashboard at:

```text
/admin/oban
```

Oban Web complements Polly's recipient-level invitation status. The poll access page remains the administration interface for sending invitations and reviewing member outcomes; Oban Web is the operational interface for inspecting queues, retries, execution failures, and worker health.

Dashboard requirements:

- require an authenticated Polly administrator;
- deny access to unauthenticated visitors;
- use an `Oban.Web.Resolver` that returns `:read_only` by default;
- do not allow retry, cancellation, deletion, queue pausing, queue scaling, or job insertion until Polly has explicit operational roles and authorization rules;
- mount the dashboard in production as well as development, subject to the same administrator authentication boundary;
- add a discoverable administration link labelled **Background jobs** or **Email jobs**;
- verify that job arguments contain only `delivery_id` and no email address, member name, token, or voting URL; and
- treat stack traces and recorded errors as administrator-sensitive operational information.

If mutable job controls are enabled in a later iteration, every permitted action must be deliberately authorized. Retrying an invitation job can cause an external email side effect, so dashboard write access must not inherit automatically from ordinary poll-management access.

## Testing strategy

### Domain tests

- Classifies every readiness category correctly.
- Allows invitations only for open polls.
- Skips members who have already voted.
- Does not automatically issue or reissue grants.
- Creates one initial delivery per grant.
- Allows explicit resends with separate history.
- Prevents duplicate initial deliveries under repeated or concurrent enqueue requests.
- Commits delivery records, jobs, and the audit event atomically.
- Keeps restricted values out of audit metadata.

### Worker tests

- Sends the expected HTML and plain-text email through the test adapter.
- Addresses only the intended recipient.
- Builds the correct private URL without persisting it.
- Records adapter success as accepted.
- Retries transient failures.
- Marks permanent failures as failed.
- Marks exhausted attempts as failed.
- Cancels when the poll closes before execution.
- Cancels when the grant is revoked or expires before execution.
- Cancels when the member is deactivated or their email changes.
- Cancels when a ballot is submitted before execution.
- Does not send an already accepted delivery again.
- Does not leak sensitive data into captured logs or job arguments.

### LiveView tests

- Displays readiness counts and skip reasons.
- Disables bulk sending for draft and closed polls.
- Requires confirmation for bulk sends and resends.
- Shows the enqueue result without waiting for delivery.
- Displays queued, sent, failed, and cancelled states.
- Uses stable DOM IDs for the invitation section, confirmation form, bulk action, and member actions.
- Preserves filters and expanded details after status refreshes.

### Oban Web tests

- Redirects or forbids unauthenticated dashboard requests.
- Allows authenticated administrators to view `/admin/oban`.
- Configures the initial dashboard resolver as read-only.
- Prevents retry, cancel, delete, insert, pause, scale, and stop operations.
- Confirms that invitation job arguments expose only the delivery ID.

### Configuration tests

- Development uses the local adapter.
- Tests use the Swoosh test adapter without network access.
- Production rejects or disables invitation sending when required mailer configuration is absent.
- Generated production links use the configured HTTPS origin.

## Migration and rollout plan

1. Add the invitation-delivery resource and database migration.
2. Add Oban, its migration, SQLite engine configuration, and application supervision.
3. Add runtime mailer, sender, and canonical URL configuration.
4. Implement readiness classification and enqueue services.
5. Implement the email builder and worker.
6. Add audit integration.
7. Add the administration UI behind a feature flag or disabled-until-configured check.
8. Verify Resend delivery in a non-production environment using a restricted API key.
9. Verify Polly's sender domain in Resend and publish the required DNS records.
10. Enable production sending with conservative queue concurrency and monitor failure rates.
11. In the operational-hardening iteration, install Oban Web, mount `/admin/oban`, and enforce read-only administrator access.

If a background-job dependency is deliberately deferred, the feature should remain disabled rather than fall back to non-durable sending.

## Acceptance criteria

- An administrator can enqueue invitations for all ready members of an open poll.
- Every queued recipient gets an independent delivery record and background job.
- Every message contains only that recipient's private voting link.
- Draft and closed polls cannot send invitations.
- Missing, revoked, expired, inactive, and already-voted recipients are skipped with accurate counts.
- Repeating or concurrently submitting the same initial operation does not create duplicate initial deliveries.
- A resend is explicit and is retained as a separate attempt.
- State changes before worker execution cancel unsafe sends.
- Transient provider failures retry and terminal failures become visible.
- The UI describes provider acceptance accurately and does not promise inbox delivery.
- Audit events contain aggregate action data but no email addresses, tokens, URLs, or recipient lists.
- Tests make no real email-provider requests.

## Deferred iterations

Likely follow-up work includes:

- scheduled sends;
- reminders limited to members who have not voted;
- configurable reminder cadence and suppression;
- bounce and complaint webhooks;
- provider-confirmed delivery status;
- editable and localized templates;
- invitation previews that send a non-functional sample to the administrator;
- delivery-history export without private URLs;
- retention and automated redaction of recipient email snapshots; and
- multi-node queue and database support.

## Open decisions before implementation

1. What verified Resend sender domain, sender identity, and reply-to identity will Polly use?
2. What is the required retention period for recipient email snapshots, Resend email IDs, and delivery records?
3. Should the poll description be included by default, or should the initial template use only the title?
4. Does Polly need a feature flag, or is configuration readiness sufficient to control rollout?
5. What queue concurrency and retry limits match the selected Resend plan and rate limits?

## References

- [Swoosh mailer documentation](https://hexdocs.pm/swoosh/Swoosh.Mailer.html)
- [Swoosh adapter contract](https://hexdocs.pm/swoosh/Swoosh.Adapter.html)
- [Swoosh test adapter](https://hexdocs.pm/swoosh/Swoosh.Adapters.Test.html)
- [Swoosh Resend adapter](https://hexdocs.pm/swoosh/Swoosh.Adapters.Resend.html)
- [Resend email API](https://resend.com/docs/api-reference/emails/send-email)
- [Resend domain verification](https://resend.com/docs/dashboard/domains/introduction)
- [Oban documentation](https://hexdocs.pm/oban/Oban.html)
- [Oban installation and SQLite engine requirements](https://hexdocs.pm/oban/installation.html)
- [Oban Web installation](https://oban-web.hexdocs.pm/installation.html)
- [Oban Web access controls](https://hexdocs.pm/oban_web/Oban.Web.Resolver.html)
