# Polly

Polly is a Phoenix and Ash application for running private, configurable polls. Its Touchpad interface gives administrators a complete workflow for managing members, configuring polls, distributing private voting links, monitoring participation, and publishing results.

Polly is the successor to Nominator, a swimmer-award proof of concept. The current application generalizes that model around reusable members, poll-scoped eligibility, independently managed poll lifecycles, and one final single-choice ballot per voter.

## Current capabilities

- Administrator authentication with confirmation and password reset.
- Member management and CSV member import with validation and preview.
- Draft poll configuration with title-derived slugs and text options.
- Poll duplication, optionally including options and the electorate.
- Electorate snapshots with unique, revocable, and reissuable access grants.
- Draft, open, and closed poll lifecycle controls.
- Token-based public voting with review and final submission states.
- Poll-scoped turnout and results with explicit result publication.
- Aggregate CSV result exports with no member identities or ballot-level data.
- Individual and bulk email invitation delivery through durable Oban jobs.
- Touchpad-styled multipart invitation emails with HTML and plain-text bodies.
- Per-member invitation status, explicit resends, and safe failure categories.
- Administrator audit history for poll, option, member, import, and invitation actions.
- Read-only Oban Web diagnostics for authenticated administrators.
- SQLite-backed single-machine deployment support for Fly.io.

## Polling rules

- A poll starts as a draft and requires at least two options before opening.
- The administrator explicitly selects eligible members for each poll.
- Each eligible member receives a private credential scoped to that member and poll.
- A member may submit one single-choice ballot per poll.
- Submitted ballots are final and cannot be edited or resubmitted.
- Options and eligibility are frozen when voting opens.
- Polls are opened and closed manually; lifecycle changes move forward only.
- Results remain private until an administrator explicitly publishes them.
- Published results are visible to members whose access grants remain valid.

Access links are bearer credentials and must be distributed privately. Polly derives voter identity from the access grant and never trusts a member ID supplied by the browser.

## Architecture

Polly uses:

- Phoenix 1.8 and LiveView for the web interface;
- Ash Framework resources, actions, policies, and Ash SQLite persistence;
- SQLite for application data;
- Oban with its SQLite engine for durable invitation jobs;
- Swoosh for multipart email construction;
- Resend for production email delivery; and
- Phoenix PubSub for live poll and result updates.

The core polling resources are:

- `Member` — a person who may be eligible to vote;
- `Poll` — the configuration and lifecycle of one poll;
- `Option` — an administrator-defined choice belonging to a poll;
- `Eligibility` — membership in a poll's electorate;
- `AccessGrant` — a revocable poll-and-member-specific credential;
- `Ballot` — one member's final submission for one poll;
- `Selection` — the option recorded against a ballot; and
- `InvitationDelivery` — durable, token-free email delivery history.

## Development

Install Elixir, Erlang/OTP, and SQLite, then install dependencies, prepare the database, seed it, and build assets:

```sh
mix setup
```

Start Phoenix:

```sh
mix phx.server
```

Or start it inside IEx:

```sh
iex -S mix phx.server
```

Visit [http://localhost:4000](http://localhost:4000).

### Create an administrator

Public account registration is disabled. Provision an administrator from a trusted shell:

```sh
POLLY_ADMIN_PASSWORD="a secure password" mix polly.admin.create admin@example.com
```

Bootstrap accounts default to the `owner` role. To create a less-privileged
account ahead of role enforcement, pass `--role administrator`, `auditor`, or
`operator`:

```sh
POLLY_ADMIN_PASSWORD="a secure password" mix polly.admin.create admin@example.com --role administrator
```

In development, retrieve the confirmation message from the local mailbox at [http://localhost:4000/dev/mailbox](http://localhost:4000/dev/mailbox).

From a trusted release shell, recover ownership for an existing confirmed,
active account with:

```sh
mix polly.admin.promote_owner admin@example.com
```

Inspect account lifecycle fields in IEx without changing state:

```elixir
Polly.Accounts.User
|> Ash.read!(authorize?: false)
|> Enum.map(&Map.take(&1, [:id, :email, :role, :status, :confirmed_at]))
```

### Local email testing

Development uses `Swoosh.Adapters.Local`, so messages are captured rather than sent over the internet. The local mailbox renders the HTML invitation and retains its plain-text alternative:

```text
http://localhost:4000/dev/mailbox
```

To exercise the invitation flow:

1. Create or import a member with an email address.
2. Create a poll with at least two options.
3. Add the member to its electorate.
4. Open the poll.
5. Visit the poll's **Access links** page and send the invitation.
6. Open the message in the local mailbox.

### Background-job diagnostics

Authenticated administrators can inspect queues, attempts, and worker errors at:

```text
http://localhost:4000/admin/oban
```

The embedded Oban Web dashboard is intentionally read-only. Retrying, cancelling, deleting, inserting, pausing, and scaling jobs are disabled until Polly has dedicated operational roles and auditing for those actions.

Phoenix LiveDashboard remains available in development at [http://localhost:4000/dev/dashboard](http://localhost:4000/dev/dashboard).

## Production email configuration

Production uses Resend through `Swoosh.Adapters.Resend`. Configure these secrets and runtime values:

- `RESEND_API_KEY` — Resend API key;
- `POLLY_FROM_EMAIL` — sender address on a Resend-verified domain; and
- `POLLY_FROM_NAME` — sender display name, defaulting to `Polly`.

Never commit these values. A local ignored `.envrc` may be used during development, while hosted environments should use their secret manager. Resend accepting a message means “sent” in Polly; it does not prove inbox delivery or that the recipient read it.

## Fly.io deployment

The initial Fly.io architecture runs a single application Machine with Phoenix, Oban Lite, and a SQLite database on the `/data` volume. Do not horizontally scale this configuration: Fly Volumes are local to one Machine, and a second independently mounted volume would contain a different database.

Required production settings include:

- `DATABASE_PATH=/data/polly.db`;
- `MIGRATE_ON_START=true`;
- `PHX_HOST` and `PHX_SERVER=true`;
- `SECRET_KEY_BASE`;
- `TOKEN_SIGNING_SECRET`;
- the Resend settings above; and
- a persistent volume mounted at `/data`.

The unauthenticated `GET /health` endpoint is used for Fly health checks. See the [Fly.io deployment guide](docs/flyio-deployment.md) for provisioning, GitHub Actions, secrets, backups, rollback, and troubleshooting.

## Quality checks

Run the full pre-commit suite before submitting changes:

```sh
mix precommit
```

This compiles with warnings treated as errors, removes unused dependency locks, formats the code, and runs the test suite.

For a focused test file:

```sh
mix test test/polly/polls/invitations_test.exs
```

## Product and technical documentation

- [Feature roadmap](docs/features-roadmap.md)
- [Configurable polls proposal](docs/configurable-polls-proposal.md)
- [First-release decisions](docs/first-release-decisions.md)
- [CSV member upload specification](docs/csv-member-upload-spec.md)
- [Poll duplication specification](docs/poll-duplication-spec.md)
- [Email invitation delivery specification](docs/email-invitation-delivery-spec.md)
- [Administrator audit trail specification](docs/admin-audit-trail-spec.md)
- [Administrator user management specification](docs/administrator-user-management-spec.md)
- [Anonymous choices specification](docs/anonymous-choices-spec.md)
- [Poll archiving specification](docs/poll-archiving-spec.md)
- [Access-link CSV export specification](docs/access-link-csv-export-spec.md)
- [CSV results export specification](docs/csv-results-export-spec.md)

## Framework documentation

- [Phoenix](https://hexdocs.pm/phoenix)
- [Ash Framework](https://hexdocs.pm/ash)
- [Oban](https://hexdocs.pm/oban)
- [Swoosh](https://hexdocs.pm/swoosh)
