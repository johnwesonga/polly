High-value next features
- CSV member upload — bulk-create member rosters using the existing specification. [DONE]
- Poll duplication iteration 2 — optionally copy options and electorate. [DONE]
- Administrator audit trail — record lifecycle, electorate, access, and configuration changes. [DONE]
- Email invitation delivery — send private voting links directly to eligible members.
- Access-link CSV export — export member names, emails, link status, and private URLs for controlled distribution.
- Scheduled opening and closing — configure lifecycle timestamps instead of requiring manual actions.
- Reminder emails — notify eligible members who have not voted without revealing their selections.
- Poll archiving — hide completed polls from normal administration while retaining history.
Poll configuration
- Multiple-choice polls with configurable selection limits.
- Ranked-choice voting.
- Yes/no and approval voting templates.
- Option descriptions or supporting links.
- Option images, where appropriate.
- Poll-level instructions and confirmation copy.
- Anonymous polls that retain eligibility enforcement but separate ballots from member identities.
- Reusable poll templates independent of historical polls.
Electorate management
- Member groups, teams, or segments.
- Bulk electorate selection.
- Saved electorate presets.
- Member tags and filtering.
- Electorate preview with active/inactive warnings.
- Eligibility cutoff snapshots.
- Waitlists or alternate voters.
- Member self-service profile correction.
Results and reporting
- CSV result exports.
- Turnout exports by poll.
- Printable or PDF result summaries.
- Result comparison across recurring polls.
- Participation history without exposing individual selections.
- Quorum requirements.
- Configurable tie-handling rules.
- Result publication notes.
- Public result pages without voting credentials.
- Embeddable result charts.
Access and security
- Expiring voting links.
- Bulk link revocation and reissue.
- One-time invitation delivery tracking.
- Administrator roles and permissions.
- Multi-factor authentication for administrators.
- Rate limiting on public voting routes.
- Suspicious link-use monitoring.
- Configurable data-retention policies.
- Stronger token-redaction and security-event logging.
Operational improvements
- Dashboard showing open polls requiring attention.
- Poll readiness checklist.
- Background jobs for email, schedules, and exports.
- Database backup and recovery tooling.
- Health and delivery-status monitoring.
- Production deployment documentation.
- PostgreSQL migration path for larger or multi-node installations.
- Webhook or API integrations.