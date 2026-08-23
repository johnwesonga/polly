# Polly

Polly is a Phoenix and Ash application for running configurable polls. It is the
greenfield successor to Nominator, a swimmer-award proof of concept, and is
designed around generic members, poll-scoped access, and independently managed
poll lifecycles.

The initial product is a complete single-choice polling flow. Broader platform
features such as ranked voting, write-ins, public results, scheduling, and
audience segments are intentionally deferred.

See [the configurable polls proposal](docs/configurable-polls-proposal.md) for
the full product and domain design. The decisions made during bootstrap are in
[the first-release decision record](docs/first-release-decisions.md).

## First-release rules

- An administrator creates a draft poll with at least two text options.
- The administrator explicitly selects the eligible members for each poll.
- Each eligible member receives a unique, revocable link for that poll.
- Each member may submit one single-choice ballot per poll.
- Submitted ballots are final and cannot be edited or resubmitted.
- Options and eligibility are frozen when voting opens.
- Polls are opened and closed manually.
- Results remain private while voting is open and after closing until an
  administrator explicitly publishes them.
- Published results are visible to members whose access grants remain valid.

Access links are credentials and must be distributed privately. The server must
derive the member from the access grant rather than trust a member ID supplied
by the browser.

## Proposed domain

The polling domain consists of:

- `Member` — a person who may be eligible to vote;
- `Poll` — the configuration and lifecycle of one poll;
- `Option` — an administrator-defined text choice belonging to a poll;
- `Eligibility` — a snapshot of a poll's electorate;
- `AccessGrant` — a revocable, poll-and-member-specific credential;
- `Ballot` — one member's submission state for one poll; and
- `Selection` — a choice recorded against a ballot.

Ballot submission will be a single transactional domain action that validates
the poll, option, eligibility, access grant, and duplicate-submission rules
together. Results and real-time events will also be scoped to an individual
poll.

## Delivery plan

0. **Bootstrap (complete)** — establish the new project, administrator
   authentication, test foundation, and remaining product decisions.
1. **Poll foundation (complete)** — implement polls, text options, lifecycle
   actions, and authenticated configuration pages.
2. **Electorate and access (complete)** — add member management, eligibility
   snapshots, revocable member links, electorate selection, and ballot preview.
3. **Phase 3A: Ballot domain and submission integrity (complete)** — Ballot and
   Selection resources, transactional single-choice submission, cross-poll
   validation, finality, and concurrency protection are implemented.
4. **Phase 3B: Public voting experience and cutover (complete)** — the
   token-based public route provides a responsive ballot and review UI,
   confirmation, and denied or duplicate-submission states.
5. **Phase 4: Results and operations (complete)** — turnout, poll-scoped
   results and PubSub, lifecycle controls, publication, and member result views
   are implemented.
6. **Hardening** — verify concurrency, authorization, token handling, logging,
   deployment, and operator documentation.

Phases 0 through 4 are complete. The protected administrator area supports
member management, draft poll and option configuration, electorate snapshots,
revocable poll-and-member-specific access links, lifecycle operations, turnout,
and final results. Eligible members can use private links to submit one final
ballot and view results after explicit publication. The remaining delivery work
is hardening and deployment readiness.

## Development

Requirements include Elixir, Erlang/OTP, and the database configured for the
current environment.

Install dependencies, create the database, run migrations and seeds, and build
the assets:

```sh
mix setup
```

Start the Phoenix endpoint:

```sh
mix phx.server
```

Alternatively, start it inside IEx:

```sh
iex -S mix phx.server
```

Visit [http://localhost:4000](http://localhost:4000).

### Create an administrator

Public account registration is disabled. Provision an administrator from a
trusted shell:

```sh
POLLY_ADMIN_PASSWORD="a secure password" mix polly.admin.create admin@example.com
```

In development, open [http://localhost:4000/dev/mailbox](http://localhost:4000/dev/mailbox)
to retrieve the account confirmation message.

## Quality checks

Run the project's full pre-commit checks before submitting changes:

```sh
mix precommit
```

This compiles with warnings treated as errors, removes unused dependency locks,
formats the code, and runs the test suite.

## Further reading

- [Phoenix documentation](https://hexdocs.pm/phoenix)
- [Ash documentation](https://hexdocs.pm/ash)
- [Phoenix deployment guide](https://hexdocs.pm/phoenix/deployment.html)
