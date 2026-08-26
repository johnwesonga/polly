# Deploying Polly to Fly.io with GitHub Actions

## Status

Proposed deployment guide. Polly is not yet deployment-ready because the required Docker, release, Fly configuration, health endpoint, and production SQLite path changes have not been implemented.

## Architecture

The initial production deployment uses:

```text
GitHub push to main
        |
        v
GitHub Actions
  1. Run mix precommit
  2. Ask Fly.io to build the image remotely
  3. Deploy after tests pass
        |
        v
One Fly Machine
  Phoenix + Oban Lite + Resend
        |
        v
/data/polly.db on one persistent Fly Volume
```

This architecture deliberately runs one application Machine. Fly Volumes are local to a Machine and cannot be mounted by multiple Machines simultaneously. Adding another Machine with another volume would create an independent Polly database rather than a replica.

The initial deployment therefore accepts:

- brief downtime during some deployments and host incidents;
- a single-machine availability boundary; and
- the need for an explicit backup and restore procedure.

When Polly requires multiple application Machines, higher availability, or multiple regions, migrate the Ash data layer and Oban engine to PostgreSQL or design and test a replicated-SQLite architecture. Do not horizontally scale the initial SQLite deployment.

## Prerequisites

- A Fly.io account and organization.
- `flyctl` installed locally.
- A GitHub repository containing Polly.
- A Resend API key.
- A sender domain verified in Resend.
- A production sender address on that domain.
- A chosen primary Fly region close to most users.

Authenticate locally:

```bash
fly auth login
```

Review available regions:

```bash
fly regions list
```

Examples in this guide use placeholders:

- `<app-name>` — globally unique Fly application name.
- `<region>` — primary region, such as `iad`, `lhr`, or `jnb`.
- `<sender-email>` — verified Resend sender address.

## Required application changes

### Production database configuration

Polly uses `AshSqlite.Repo`, but `config/runtime.exs` currently expects a PostgreSQL-style `DATABASE_URL` and socket options. Production must instead configure SQLite using a filesystem path on the mounted volume.

The production repository configuration should be equivalent to:

```elixir
database_path =
  System.get_env("DATABASE_PATH") ||
    raise "Missing environment variable `DATABASE_PATH`!"

config :polly, Polly.Repo,
  database: database_path,
  pool_size: String.to_integer(System.get_env("POOL_SIZE") || "5")
```

Remove production repository settings that apply to network databases:

```elixir
url: database_url
socket_options: maybe_ipv6
```

Do not store the database inside the application image or its ephemeral filesystem. The Fly configuration will set:

```text
DATABASE_PATH=/data/polly.db
```

### Phoenix release and Docker image

Generate the standard Phoenix release and Docker artifacts:

```bash
mix phx.gen.release --docker
```

Review rather than blindly accept the generated files. Expected artifacts include:

- `Dockerfile`;
- `.dockerignore`;
- `lib/polly/release.ex`;
- `rel/overlays/bin/migrate`; and
- `rel/overlays/bin/server`.

The runtime image must contain the operating-system libraries required by Exqlite.

Build the image locally before the first Fly deployment:

```bash
docker build -t polly:local .
```

### Database migrations on startup

Do not use Fly's `release_command` for the SQLite migration. A release command runs in a temporary Machine without the application volume, so it cannot migrate `/data/polly.db`.

Run migrations after the volume is mounted and before the supervision tree starts. One option is a guarded application-start migration:

```elixir
def start(_type, _args) do
  if System.get_env("MIGRATE_ON_START") == "true" do
    Polly.Release.migrate()
  end

  children = [
    # existing children
  ]

  Supervisor.start_link(children,
    strategy: :one_for_one,
    name: Polly.Supervisor
  )
end
```

An entrypoint that runs `bin/migrate` before `bin/server` is also acceptable. In either case, migrations must execute after `/data` is mounted.

The migration mechanism must return a non-zero exit status when migrations fail so an invalid application version does not start.

### Health endpoint

Add a lightweight unauthenticated endpoint:

```text
GET /health
```

It should return `200 OK` when the Phoenix endpoint is running. Keep the first check inexpensive and free of secrets. A later readiness endpoint may verify database connectivity separately.

The health endpoint must not reveal:

- dependency versions;
- environment variables;
- database paths;
- queue contents;
- exception details; or
- configuration values.

## One-time Fly.io provisioning

### Create the application configuration

From the repository root:

```bash
fly launch --no-deploy
```

If Fly offers to create PostgreSQL, decline it for this deployment iteration. Commit the resulting `fly.toml` after adapting it to this guide.

### Create the persistent volume

Create one encrypted volume in the application's primary region:

```bash
fly volumes create polly_data \
  --app <app-name> \
  --region <region> \
  --size 1 \
  --snapshot-retention 14
```

Confirm its placement:

```bash
fly volumes list --app <app-name>
```

Do not create a second application Machine or volume during the initial deployment.

## Suggested `fly.toml`

```toml
app = "<app-name>"
primary_region = "<region>"

[build]

[env]
  PHX_HOST = "<app-name>.fly.dev"
  PHX_SERVER = "true"
  PORT = "4000"
  DATABASE_PATH = "/data/polly.db"
  MIGRATE_ON_START = "true"
  POOL_SIZE = "5"
  POLLY_FROM_NAME = "Polly"

[mounts]
  source = "polly_data"
  destination = "/data"
  snapshot_retention = 14

[http_service]
  internal_port = 4000
  force_https = true
  auto_stop_machines = false
  auto_start_machines = true
  min_machines_running = 1

  [http_service.concurrency]
    type = "requests"
    soft_limit = 200
    hard_limit = 250

  [[http_service.checks]]
    interval = "15s"
    timeout = "2s"
    grace_period = "10s"
    method = "GET"
    path = "/health"

[[vm]]
  memory = "512mb"
  cpu_kind = "shared"
  cpus = 1
```

Replace every placeholder before committing the file.

### Why automatic stopping is disabled

Polly runs Oban for email invitation delivery. The Machine must remain running to process new jobs, retries, and future scheduled work. With automatic stopping enabled, background work might wait indefinitely for an HTTP request to wake the Machine.

## Fly application secrets

Store runtime application secrets in Fly, not GitHub and not `.envrc`:

```bash
fly secrets set \
  --app <app-name> \
  SECRET_KEY_BASE="$(mix phx.gen.secret)" \
  TOKEN_SIGNING_SECRET="$(mix phx.gen.secret)" \
  RESEND_API_KEY="<resend-api-key>" \
  POLLY_FROM_EMAIL="<sender-email>"
```

The public host, database path, port, pool size, and sender display name belong in `fly.toml`; credential material belongs in Fly secrets.

Never copy `.envrc` into the Docker image. Ensure `.dockerignore` excludes it even though Git already ignores it.

Review configured secret names without displaying their values:

```bash
fly secrets list --app <app-name>
```

## GitHub deployment token

Create an app-scoped Fly deploy token rather than using a personal or organization-wide token:

```bash
fly tokens create deploy \
  --app <app-name> \
  --name github-actions \
  --expiry 8760h
```

Copy the complete output. In GitHub, create this repository secret:

```text
Settings
  -> Secrets and variables
  -> Actions
  -> New repository secret
  -> FLY_API_TOKEN
```

Only the Fly deployment token belongs in GitHub Actions. Polly's runtime secrets remain in Fly.

For an approval gate, create a protected GitHub environment named `production` and require reviewers.

## GitHub Actions workflow

Create `.github/workflows/fly.yml`:

```yaml
name: Test and deploy

on:
  push:
    branches:
      - main
  workflow_dispatch:

permissions:
  contents: read

concurrency:
  group: polly-production
  cancel-in-progress: false

jobs:
  test:
    name: Test
    runs-on: ubuntu-latest

    env:
      MIX_ENV: test

    steps:
      - name: Check out repository
        uses: actions/checkout@v4

      - name: Install Erlang and Elixir
        uses: erlef/setup-beam@v1
        with:
          otp-version: "27.0"
          elixir-version: "1.18.1"

      - name: Restore Mix cache
        uses: actions/cache@v4
        with:
          path: |
            deps
            _build
          key: ${{ runner.os }}-mix-${{ hashFiles('mix.lock') }}
          restore-keys: |
            ${{ runner.os }}-mix-

      - name: Install dependencies
        run: mix deps.get

      - name: Run precommit checks
        run: mix precommit

  deploy:
    name: Deploy to Fly.io
    needs: test
    runs-on: ubuntu-latest
    environment: production

    steps:
      - name: Check out repository
        uses: actions/checkout@v4

      - name: Install flyctl
        uses: superfly/flyctl-actions/setup-flyctl@master

      - name: Deploy
        run: flyctl deploy --remote-only --config fly.toml
        env:
          FLY_API_TOKEN: ${{ secrets.FLY_API_TOKEN }}
```

The `test` job must succeed before `deploy` begins. `--remote-only` builds on Fly's remote builder, so the deployment runner does not need a Docker daemon.

For stronger supply-chain control, pin third-party GitHub Actions to reviewed commit SHAs rather than mutable version tags before production use.

## First deployment

Deploy from a local machine before enabling automatic production deployment:

```bash
fly deploy --app <app-name>
```

Inspect deployment state:

```bash
fly status --app <app-name>
fly checks list --app <app-name>
fly logs --app <app-name>
```

Open the application:

```bash
fly apps open --app <app-name>
```

After the local deployment succeeds, commit `fly.toml`, the Docker/release artifacts, and the GitHub workflow. The next push to `main` will exercise continuous deployment.

## Verification checklist

### Application

- The health check returns `200`.
- The sign-in page loads over HTTPS.
- An administrator can sign in.
- Poll creation and editing persist.
- A Machine restart does not erase data.
- Static assets and LiveView connections work.

### Database

- `/data/polly.db` exists on the mounted volume.
- All migrations have run.
- Foreign-key enforcement is active.
- SQLite uses the expected journal mode.
- Only one application Machine is running.

Inspect the database location from a remote IEx session or release evaluation:

```elixir
Polly.Repo.query!("PRAGMA database_list")
```

### Email and background work

- Resend accepts an invitation email.
- The sender uses the verified production domain.
- The Oban `mailers` queue is running.
- An invitation job moves to completed.
- Retryable jobs execute without an HTTP request waking the Machine.
- Tokens and private voting URLs do not appear in logs or Oban arguments.

### GitHub Actions

- Pull request checks or local checks pass before merging.
- A failing test prevents deployment.
- A successful push to `main` deploys once.
- Concurrent pushes do not run overlapping production deployments.
- The workflow has only read access to repository contents.
- The Fly token is app-scoped.

## Backups

Fly automatically creates daily volume snapshots. They are useful for recovery but should not be Polly's only backup method because changes since the latest snapshot may be lost.

List snapshots:

```bash
fly volumes list --app <app-name>
fly volumes snapshots list <volume-id>
```

Create an on-demand snapshot before a high-risk migration:

```bash
fly volumes snapshots create <volume-id>
```

Restore into a new volume of equal or greater size:

```bash
fly volumes create polly_data_restored \
  --app <app-name> \
  --snapshot-id <snapshot-id> \
  --size 1
```

In addition to Fly snapshots, establish an application-aware SQLite backup procedure and periodically test restoration. A backup that has never been restored is not a verified recovery plan.

## Deployment rollback

Application rollback and database rollback are separate concerns.

- Use Fly release history and image deployment to restore an earlier application version.
- Do not assume an older application image is compatible with a migrated database.
- Prefer backward-compatible migrations that allow the previous release to run during rollback.
- Take an on-demand volume snapshot before destructive or irreversible migrations.
- Restore a volume snapshot only as a deliberate data-recovery operation because it discards changes made after that snapshot.

Inspect releases before rollback:

```bash
fly releases --app <app-name>
```

## Operational commands

```bash
fly status --app <app-name>
fly logs --app <app-name>
fly checks list --app <app-name>
fly machines list --app <app-name>
fly volumes list --app <app-name>
fly secrets list --app <app-name>
fly ssh console --app <app-name>
```

Avoid running destructive SQLite commands from multiple shells or processes.

## Scaling boundary

Do not run multiple normal Polly Machines against separate SQLite volumes. Before horizontal scaling, choose one of these paths:

1. Migrate Polly from AshSqlite to PostgreSQL and use Oban's PostgreSQL engine.
2. Adopt a supported replicated-SQLite architecture and validate Ash, Ecto, migrations, Oban, failover, and write consistency against it.

PostgreSQL is the lower-risk path when Polly needs conventional multi-node deployment.

## Implementation checklist

- [ ] Replace production `DATABASE_URL` configuration with `DATABASE_PATH`.
- [ ] Generate and review Phoenix Docker/release artifacts.
- [ ] Run SQLite migrations after the volume is mounted.
- [ ] Add `GET /health`.
- [ ] Run `mix precommit`.
- [ ] Create the Fly application without deploying.
- [ ] Create one persistent volume in the primary region.
- [ ] Add and review `fly.toml`.
- [ ] Configure Fly application secrets.
- [ ] Verify the Resend sender domain.
- [ ] Create an app-scoped deploy token.
- [ ] Add the `FLY_API_TOKEN` GitHub secret.
- [ ] Add the GitHub Actions workflow.
- [ ] Perform and verify the first deployment locally.
- [ ] Enable deployment from `main`.
- [ ] Verify automatic volume snapshots.
- [ ] Implement and test an additional SQLite backup.
- [ ] Document and rehearse restoration.

## References

- [Fly.io continuous deployment with GitHub Actions](https://fly.io/docs/launch/continuous-deployment-with-github-actions/)
- [Fly.io access tokens](https://fly.io/docs/security/tokens/)
- [Fly.io Phoenix deployment](https://fly.io/docs/elixir/getting-started/)
- [Fly.io SQLite deployment](https://fly.io/docs/elixir/advanced-guides/sqlite3/)
- [Fly.io application configuration](https://fly.io/docs/reference/configuration/)
- [Fly.io Volumes overview](https://fly.io/docs/volumes/overview/)
- [Fly.io volume snapshots](https://fly.io/docs/volumes/snapshots/)
- [AshSqlite deployment guidance](https://hexdocs.pm/ash_sqlite/getting-started-with-ash-sqlite.html)
- [Ecto SQLite configuration](https://ecto-sqlite3.hexdocs.pm/)

