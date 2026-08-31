# Polly feature roadmap

This roadmap tracks shipped capabilities and possible future work. Features with a dedicated technical specification link directly to it.

Status labels:

- **Done** — implemented and available in the application.
- **Specified** — design exists, but implementation is not complete.
- **Proposed** — roadmap idea that still needs product and technical design.

## Delivered features

- **Done — [CSV member upload](csv-member-upload-spec.md):** bulk-create member rosters with validation, preview, and explicit confirmation.
- **Done — [Poll duplication](poll-duplication-spec.md):** copy poll details and optionally copy active options and electorate members into a new draft.
- **Done — [Administrator audit trail](admin-audit-trail-spec.md):** record and inspect consequential poll, option, electorate, access, member, import, and invitation actions.
- **Done — [Email invitation delivery](email-invitation-delivery-spec.md):** send private voting links through durable Oban jobs with delivery status, explicit resend, and read-only operational diagnostics.

## High-value next features

- **Specified — [Access-link CSV export](access-link-csv-export-spec.md):** export member names, emails, link status, and private URLs for controlled distribution.
- **Specified — [Poll archiving](poll-archiving-spec.md):** hide completed polls from normal administration while retaining their history.
- **Proposed — Scheduled opening and closing:** configure lifecycle timestamps instead of requiring manual actions.
- **Proposed — Reminder emails:** notify eligible members who have not voted without revealing their selections.

## Poll configuration

- **Specified — [Multiple-choice polls with configurable selection limits](multiple-choice-polls-spec.md):** support choose-up-to, exact-count, and minimum-to-maximum selection rules.
- **Specified — [Anonymous choices with participation tracking](anonymous-choices-spec.md):** retain eligibility enforcement and participation records while separating ballots from member identities.
- **Proposed — Ranked-choice voting.**
- **Proposed — Yes/no and approval voting templates.**
- **Proposed — Option descriptions or supporting links.**
- **Proposed — Option images, where appropriate.**
- **Proposed — Poll-level instructions and confirmation copy.**
- **Proposed — Reusable poll templates independent of historical polls.**

## Electorate management

- **Proposed — Member groups, teams, or segments.**
- **Proposed — Bulk electorate selection.**
- **Proposed — Saved electorate presets.**
- **Proposed — Member tags and filtering.**
- **Proposed — Electorate preview with active/inactive warnings.**
- **Proposed — Eligibility cutoff snapshots.**
- **Proposed — Waitlists or alternate voters.**
- **Proposed — Member self-service profile correction.**

## Results and reporting

- **Done — [CSV result exports](csv-results-export-spec.md):** download aggregate, one-row-per-option results without member identities or ballot-level data.
- **Proposed — Turnout exports by poll.**
- **Proposed — Printable or PDF result summaries.**
- **Proposed — Result comparison across recurring polls.**
- **Proposed — Participation history without exposing individual selections.**
- **Proposed — Quorum requirements.**
- **Proposed — Configurable tie-handling rules.**
- **Proposed — Result publication notes.**
- **Done — [Public result pages without voting credentials](public-result-pages-spec.md):** expose only closed, published aggregate results through an explicitly enabled, credential-free URL.
- **Proposed — Embeddable result charts.**

## Access and security

- **Done — [One-time invitation delivery tracking](email-invitation-delivery-spec.md):** retain safe per-attempt delivery state without persisting private URLs in jobs or audit metadata.
- **Specified — [Voter credential protection](voter-credential-protection-spec.md):** prevent administrators from retrieving working voting links while preserving durable delivery, rotation, revocation, and eligibility enforcement.
- **Proposed — Delivery-status CSV export:** replace the superseded [credential-bearing access-link export](access-link-csv-export-spec.md) with member, eligibility, and delivery status that contains no private URLs.
- **Proposed — Expiring voting links.**
- **Proposed — Bulk link revocation and reissue.**
- **Specified — [Administrator user management and roles](administrator-user-management-spec.md):** owner-managed invitations, account lifecycle controls, final-owner protection, and role-based authorization.
- **Proposed — Multi-factor authentication for administrators.**
- **Proposed — Rate limiting on public voting routes.**
- **Proposed — Suspicious link-use monitoring.**
- **Proposed — Configurable data-retention policies.**
- **Proposed — Stronger token-redaction and security-event logging.**

## Operational improvements

- **Done — [Background email jobs and diagnostics](email-invitation-delivery-spec.md):** durable Oban processing with an authenticated, read-only Oban Web dashboard.
- **Done — [Fly.io production deployment documentation](flyio-deployment.md):** single-machine SQLite deployment with GitHub Actions, persistent storage, health checks, and Resend configuration.
- **Specified — [Role-aware administration dashboard](admin-dashboard-spec.md):** surface poll status, work requiring attention, active-poll turnout, account risks, recent activity, and delivery health according to administrator permissions.
- **Proposed — Poll readiness checklist.**
- **Proposed — Background jobs for schedules and exports.**
- **Proposed — Database backup and recovery tooling.**
- **Proposed — Expanded health and delivery monitoring.**
- **Proposed — PostgreSQL migration path for larger or multi-node installations.**
- **Proposed — Webhook or API integrations.**

## Supporting design documents

- [Configurable polls proposal](configurable-polls-proposal.md)
- [First-release decisions](first-release-decisions.md)
- [Fly.io deployment guide](flyio-deployment.md)
