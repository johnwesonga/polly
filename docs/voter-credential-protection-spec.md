# Voter Credential Protection — Technical Specification

## Status

In progress. Phase 1 administrator UI containment is implemented: working
voting URLs and Copy controls are no longer rendered, administrator-facing
queries avoid selecting the token, lifecycle and email-delivery controls remain
available, and regression tests assert that credentials do not appear in the
administrator HTML. Plaintext database storage and worker-time token access
remain until the derived-credential phases are implemented.

## Summary

Prevent Polly administrators from using member voting credentials that they can currently view through access-link administration screens or exports.

The current voting URL is a bearer credential: possession of the URL is sufficient to act as the eligible member. Consequently, any role that can retrieve or export the full URL can submit that member's ballot. Ash field sensitivity, redacted inspection, audit logs, and policy checks do not solve this while the application deliberately renders the credential to an administrator.

The recommended design removes recoverable credentials from administrator workflows and database rows. Administrators retain lifecycle controls—delivery status, send, resend, revoke, and reissue—but cannot view or copy a working voting URL. Durable email jobs derive a credential using a dedicated server secret and a persisted random nonce, store only its digest, and send it directly to the member. Stronger mailbox verification can be added later for organizations that need protection even from staff with broader operational access.

This is a medium-to-high complexity security change. Token verification is straightforward, but durable delivery, retry behavior, credential rotation, rollout of existing links, exports, administrator roles, incident recovery, and voter communication must remain consistent.

## Problem statement

Today an administrator with access-link management permission can:

1. view a member's private voting URL;
2. copy or export the URL;
3. open it outside the administrator session; and
4. submit the member's final ballot.

Blocking the route only when an administrator session is present is insufficient. The same person can use another browser, clear the session, or send the link elsewhere.

The security boundary must therefore be possession and delivery of a credential that the administrator interface never reveals—not the browser session used to open it.

## Goals

- Prevent application administrators from retrieving working voting credentials.
- Preserve eligibility enforcement and one-final-ballot semantics.
- Keep invitation delivery asynchronous and retryable through Oban.
- Store no plaintext voting token in the database, audit events, job arguments, logs, telemetry, or exports.
- Allow administrators to inspect delivery state without seeing credentials.
- Allow explicit resend, revoke, and reissue operations.
- Ensure resend behavior is deterministic and safe under Oban retries.
- Notify a member when their ballot is submitted without revealing their choices.
- Preserve future compatibility with anonymous-choice ballots.
- Provide a staged migration from existing plaintext access grants.

## Non-goals

- Preventing a trusted infrastructure operator with production secrets and code execution from impersonating a voter in the initial implementation.
- Proving how an individual voted.
- Allowing administrators to recover a member's old voting link.
- Allowing submitted ballots to be edited or casually deleted.
- Replacing email delivery with member accounts in the first iteration.
- Cryptographic election verification, end-to-end encrypted ballots, or coercion resistance.
- Making ballots anonymous; the anonymous-choices specification addresses identity separation.

## Threat model

### Protected against

- owners and administrators using the normal Polly UI;
- users with permission to manage access grants or send invitations;
- accidental exposure through CSV exports;
- application logs, audit metadata, Oban arguments, exception reports, or IEx inspection of database records;
- read-only database access without the separate credential-derivation secret.

### Trusted in the initial implementation

- the running application process;
- the deployment platform and secret store;
- operators who can read production secrets or execute arbitrary release code;
- the configured email provider and the member's mailbox.

If operational staff must also be technically unable to impersonate voters, implement the mailbox-verification phase and consider stronger organizational or cryptographic controls.

## Security principles

1. A voting credential is a password, not administrative data.
2. Administrator permission to manage credential lifecycle does not imply permission to read a credential.
3. Credentials are shown only to the intended recipient through the configured delivery channel.
4. Database and job state must be safe to inspect without revealing a working URL.
5. Every rotation invalidates prior credentials according to an explicit overlap policy.
6. Delivery retries must not silently change the credential sent to the member.
7. Voter-choice data must never appear in credential, delivery, or security audit events.

## Recommended credential design

### Persisted fields

Replace the plaintext `AccessGrant.token` with fields such as:

| Field | Purpose |
| --- | --- |
| `token_digest` | One-way digest used to resolve a supplied token. |
| `credential_nonce` | Random, non-secret input used with the server secret to derive the token. |
| `credential_version` | Monotonic version used to identify stale jobs and rotations. |
| `issued_at` | Time the current credential became valid. |
| `expires_at` | Optional credential expiry. |
| `revoked_at` | Explicit revocation timestamp. |

`token_digest` and `credential_nonce` must be marked sensitive. The nonce alone must not be sufficient to generate a valid token.

Do not persist:

- the plaintext token;
- the complete voting URL;
- an encrypted URL using the general application database key; or
- the token in an invitation-delivery row.

### Derivation

Configure a dedicated production secret such as:

```text
POLLY_VOTER_TOKEN_SECRET
```

Do not reuse `SECRET_KEY_BASE`, the Resend API key, or an administrator credential.

For a grant and credential version, derive a stable token using an HMAC-based function over domain-separated inputs:

```text
token = base64url(HMAC-SHA-256(secret, "voter-access:v1:" <> grant_id <> nonce <> version))
token_digest = SHA-256(token)
```

The exact encoding and concatenation must use an unambiguous binary format rather than informal string concatenation. Use constant-time comparison when resolving a supplied token.

This provides the properties needed by Oban:

- the raw token is never stored;
- a retry for the same grant version derives the same token;
- job arguments need only the grant ID and version;
- a database reader without the server secret cannot reconstruct the token; and
- rotation changes the nonce/version and invalidates the previous token.

The server secret should be loaded through runtime configuration and must not be checked into source control.

### Token resolution

`AccessGrant.resolve/2` should:

1. validate the token's transport format and maximum size;
2. hash the supplied token;
3. query by `poll_id` and `token_digest`;
4. reject revoked or expired grants;
5. compare digest values in constant time where application comparison is required; and
6. return the safe existing invalid-grant response for every failure.

The route must not reveal whether the poll, member, grant, or token digest exists.

## Durable invitation delivery

### Enqueue

An authorized send or resend operation should run in one database transaction:

1. generate a new random nonce when rotation is required;
2. increment `credential_version`;
3. derive and store the new token digest;
4. create or update the safe invitation-delivery state;
5. insert an Oban job containing only `access_grant_id` and `credential_version`; and
6. commit all state together.

The raw token and URL must not appear in the job arguments.

### Worker

The worker should:

1. load the grant by ID;
2. require the job version to equal the current credential version;
3. reject revoked, expired, or stale work without sending;
4. derive the stable token in memory from the current nonce and server secret;
5. build the URL in memory;
6. send it directly to the member's email address;
7. discard the raw token and URL after the provider call; and
8. persist only safe delivery status and provider identifiers.

An Oban retry for the same version derives and sends the same URL. This avoids the failure mode where a provider accepts one email, the worker crashes before recording success, and a retry silently invalidates the first email.

### Resend and reissue

An explicit administrator resend should rotate the credential and enqueue a new version. A retry of the same Oban job is not an explicit resend and must not rotate it.

The initial policy should invalidate the previous version immediately. The UI must warn that older invitation emails will stop working. A short overlap window is possible but increases impersonation and replay risk and is not recommended initially.

## Administrator experience

Remove from administrator pages:

- full voting URLs;
- shortened but copyable URLs;
- Copy link buttons;
- token reveal controls; and
- private-link CSV exports.

Retain:

- member name and email;
- eligibility state;
- invitation delivery state;
- last delivery time;
- attempt count and safe failure information;
- Send invitation;
- Resend and rotate link;
- Revoke access; and
- Reissue access.

Use clear copy:

```text
Voting links are delivered directly to members and cannot be viewed by administrators.
```

For resend:

```text
Sending a new invitation invalidates the member's previous voting link.
```

Do not imply that hashing protects against infrastructure operators who control the application secret.

## Access-link CSV export conflict

The currently specified access-link CSV export conflicts with this feature because its purpose is to disclose working bearer credentials to administrators.

Recommended resolution:

- replace it with a **delivery-status CSV export** containing member name, email, eligibility state, delivery status, last sent time, and safe error code;
- exclude tokens and private URLs; and
- update the roadmap and existing access-link export specification before implementing either feature.

Restricting private-link export to owners is not a complete fix. It reduces the number of people who can impersonate voters but preserves the vulnerability for owners.

## Mailbox verification

For organizations requiring stronger assurance, add a second factor based on mailbox possession:

```text
Voting URL -> request short-lived code -> member receives code -> verify code -> vote
```

The voting URL identifies the grant but does not by itself authorize ballot submission. The verification code should:

- be short-lived;
- be single-use;
- be stored only as a digest;
- be rate-limited by grant, IP address, and delivery destination;
- have a small attempt limit;
- never appear in logs, jobs, or audit metadata; and
- create a short-lived verified voting session after success.

Mailbox verification protects against an administrator who obtains a voting link but cannot access the member's mailbox. It still trusts the email provider and infrastructure operators.

## Defense in depth

### Administrator-session blocking

When a signed-in administrator opens a voting route, show a warning or reject the request. This reduces accidental misuse but is not a security boundary because the administrator can use another browser session.

### Ballot-submission notification

After a ballot commits, send the member a notification containing:

- poll title;
- submission timestamp;
- a statement that the ballot is final; and
- instructions for reporting suspected misuse.

Do not include selected options. This remains safe for future anonymous-choice polls and gives members a chance to detect impersonation.

### Rate limiting

Rate-limit:

- invalid voting-token attempts;
- verification-code requests;
- verification-code submissions; and
- repeated invitation sends.

Do not use rate-limit keys or telemetry labels that expose raw credentials or create unbounded cardinality.

### Audit and security events

Continue auditing administrator actions such as:

- grant issued;
- grant revoked;
- credential rotated;
- invitation enqueued; and
- invitation delivery failed.

Never audit the raw token, URL, digest, nonce, verification code, ballot contents, or member-choice association.

Anonymous invalid-token requests should use security telemetry or structured logs rather than the administrator audit trail.

## Authorization

Keep lifecycle permissions separate:

- `:manage_electorates` controls membership in the electorate;
- `:manage_access_grants` controls grant issue, revoke, and reissue;
- `:send_invitations` controls delivery and explicit resend.

No permission should grant plaintext credential access because that capability should no longer exist.

Review owner and administrator role assignments during rollout, but do not rely on role narrowing as the primary protection.

## Migration strategy

Existing plaintext tokens require an explicit transition.

### Recommended migration

1. Add nullable digest, nonce, version, and issue-time fields.
2. Deploy code capable of resolving both legacy and derived credentials.
3. For each existing active grant, generate a nonce/version and store a derived-token digest.
4. Mark the legacy token as pending retirement; do not expose it in any UI or export.
5. Email the newly derived credential to eligible members when operationally appropriate.
6. After a communicated grace period, stop resolving legacy tokens.
7. erase the plaintext token column values;
8. remove the legacy column and dual-resolution code; and
9. verify backups and replicas follow the organization's retention policy.

An immediate cutover is safer but invalidates every existing invitation. Choose it when polls can be paused and invitations resent in a controlled maintenance window.

Schema removal does not erase tokens from old backups. Backup retention and access controls must be included in the rollout plan.

## Implementation phases

### Phase 0 — Threat model and product decisions

- Confirm whether the protected adversary is an application administrator, a database reader, or an infrastructure operator.
- Decide immediate cutover versus dual-resolution grace period.
- Decide whether ballot-submission notifications are mandatory.
- Resolve the conflict with private-link CSV exports.
- Document incident and voter-dispute handling.

No production behavior changes in this phase.

### Phase 1 — Administrator UI containment

Implemented.

- Remove full access URLs and Copy controls from the access LiveView.
- Prevent new private-link CSV export work.
- Retain delivery status, send, resend, revoke, and reissue controls.
- Add explicit administrator-facing credential-protection copy.
- Add UI and role-authorization regression tests.

This phase reduces routine exposure but does not yet protect tokens stored in the database.

### Phase 2 — Derived credentials and hashed resolution

- Add the dedicated runtime secret configuration.
- Add nonce, version, digest, and issuance fields.
- Implement deterministic HMAC derivation and constant-time verification.
- Update `AccessGrant.resolve/2` to use digests.
- Ensure IEx inspection and Ash serialization do not expose working credentials.
- Add cryptographic test vectors and invalid-token tests.

### Phase 3 — Durable delivery and rotation

- Change Oban jobs to carry grant ID and credential version only.
- Derive URLs only inside the worker process.
- Make retries stable for the same version.
- Make explicit resend rotate and invalidate the previous credential.
- Detect and safely discard stale jobs.
- Verify logs, telemetry, job inspection, and delivery records contain no credentials.

### Phase 4 — Legacy-token retirement

- Backfill derived credentials for active grants.
- Support the selected grace-period or immediate-cutover strategy.
- Deliver replacement invitations.
- Disable legacy resolution.
- erase and remove plaintext token storage.
- Update operational and Fly.io deployment documentation.

### Phase 5 — Detection and member notification

- Send a choice-free ballot-submission notification.
- Add safe security telemetry for invalid or suspicious credential use.
- Add rate limits and repeated-send controls.
- Document the dispute and recovery workflow.

### Phase 6 — Optional mailbox verification

- Add short-lived verification challenges and a verified voting session.
- Rate-limit challenge requests and attempts.
- Preserve generic, non-enumerating errors.
- Test expiration, replay, retries, abuse controls, and session invalidation.

## Test plan

### Credential tests

- The same grant nonce/version and secret derive the same token.
- Different grants, nonces, or versions derive different tokens.
- Stored rows contain no plaintext token or URL.
- Valid tokens resolve only their poll-scoped active grant.
- Unknown, malformed, expired, revoked, cross-poll, and old-version tokens fail identically.
- Digest comparison does not use ordinary string equality in security-sensitive code.

### Delivery tests

- Job arguments contain only safe identifiers and version numbers.
- A retry sends the same credential for the same version.
- Explicit resend creates a new version and invalidates the old token.
- A stale job sends nothing.
- Provider failure retains safe retry state without persisting the URL.
- Logs, exceptions, audit events, and Oban Web do not contain the token.

### Administrator tests

- No administrator role can view or copy a voting URL.
- Grant and invitation lifecycle controls still respect their separate permissions.
- Delivery status remains useful without revealing credentials.
- Exports contain no token, digest, nonce, or private URL.

### Voting tests

- Current single- and multiple-choice submission flows accept derived credentials.
- One member can still submit only one final ballot.
- Revocation and rotation take effect immediately.
- Existing-ballot and published-result views continue to work through a valid credential.
- Administrator-session blocking does not replace credential validation.

### Migration tests

- Existing grants follow the selected legacy policy.
- Backfill never logs plaintext legacy or replacement tokens.
- Old credentials stop resolving after retirement.
- Rollback behavior is documented and does not reintroduce exposed credentials silently.

### Mailbox-verification tests

- Challenges expire and are single-use.
- Codes cannot be replayed or used for another grant.
- Attempt limits and resend limits are enforced.
- Errors do not enumerate members, grants, or email addresses.

## Acceptance criteria

The core feature is complete when:

- administrators cannot retrieve a working voting credential through Polly;
- the database, Oban arguments, delivery records, logs, telemetry, audits, and exports contain no plaintext voting token or URL;
- invitation delivery remains durable and retry-safe;
- explicit resend rotates the credential while a worker retry does not;
- revoked, expired, stale, and legacy credentials follow documented behavior;
- voters can complete existing single- and multiple-choice flows using delivered credentials;
- members receive a choice-free notification after ballot submission if Phase 5 is included in the release;
- authorization and audit inventories reflect the new boundaries; and
- automated tests cover derivation, resolution, rotation, retry behavior, migration, and leakage prevention.

## Risks and likely issues

- **Email reliability:** immediate rotation can make an older delivered email invalid before a replacement arrives.
- **Retry ambiguity:** generating a random token independently on every worker attempt produces broken links; derivation must be stable for a credential version.
- **Secret rotation:** changing the derivation secret invalidates credentials unless versioned key rotation is designed explicitly.
- **Legacy backups:** removing the plaintext column does not remove tokens from retained backups.
- **Operational access:** anyone with the database nonce and production derivation secret can reconstruct credentials. Mailbox verification or stronger controls are required for that threat.
- **Support burden:** administrators lose the ability to copy a link manually for a member, making email deliverability and recovery flows more important.
- **CSV compatibility:** consumers expecting private URLs must migrate to delivery-status exports.
- **Member email absence:** members without an email address cannot receive a protected credential under the first design and need an explicitly approved alternate channel.
- **Disputed ballots:** notification reveals suspected misuse but Polly still needs a controlled policy for remediation without undermining final-ballot guarantees.

## Operational requirements

- Store `POLLY_VOTER_TOKEN_SECRET` in Fly.io secrets and equivalent local secret management.
- Never print the secret or derived tokens during release-shell troubleshooting.
- Define a versioned secret-rotation runbook before rotating the key.
- Add credential leakage checks to code review and automated tests.
- Review email-domain authentication and provider access because email becomes the primary delivery boundary.
- Include database backups, logs, error reporting, and Oban Web in the security review.

## Future extensions

- Member accounts or passkeys instead of email bearer links.
- Organization-specific identity-provider authentication.
- Mailbox OTP verification as a required rather than optional step.
- Privacy thresholds for small electorates.
- Voter-visible access and submission history.
- Formal security-event review workflows.
- Hardware-backed or external key management for token derivation secrets.

## Open questions

- Must Polly protect against application administrators only, or also production operators?
- How should members without deliverable email addresses receive credentials?
- Should resend invalidate the prior link immediately or after a short overlap window?
- What is the approved response when a member disputes a submitted ballot?
- Should ballot-submission notifications ship with hashed credentials or in a later phase?
- Is mailbox verification optional per poll, mandatory for sensitive polls, or mandatory globally?

## Related documentation

- [Access-link CSV export specification](access-link-csv-export-spec.md)
- [Email invitation delivery specification](email-invitation-delivery-spec.md)
- [Anonymous choices specification](anonymous-choices-spec.md)
- [Administrator audit trail specification](admin-audit-trail-spec.md)
- [Fly.io deployment guide](flyio-deployment.md)
