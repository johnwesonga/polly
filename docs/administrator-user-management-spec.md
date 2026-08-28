# Administrator User Management and Roles — Technical Specification

## Status

Phases 0–3 implemented; production deployment verification remains pending. Phases 4–7 proposed.

## Summary

Polly currently treats every authenticated `Polly.Accounts.User` as an unrestricted administrator. Accounts can be created from a trusted Mix task, but the application has no administrator directory, invitation workflow, activation controls, roles, or protection against disabling the last person who can manage the installation.

This feature introduces administrator lifecycle management and role-based authorization while preserving the separate meaning of `Polly.Members.Member`: users operate Polly; members are eligible voters.

The implementation is divided into independently deployable phases. It begins with a lockout-safe schema and recovery path, then adds account lifecycle controls, authorization, the management interface, invitations, and final hardening. Mutable Oban controls remain explicitly deferred.

This is a medium-to-high complexity security feature. Hiding links or buttons is insufficient. Authorization must be consistent at every domain and delivery boundary, and deactivating an account must invalidate existing sessions rather than merely preventing the next password sign-in.

## Goals

- Give owners an in-application directory of administrator accounts and pending invitations.
- Invite an administrator without the inviter choosing or learning their password.
- Allow owners to resend or revoke pending invitations.
- Allow invited recipients to set their own password and enter Polly with a confirmed account.
- Allow owners to activate and deactivate accounts without deleting history.
- Terminate or reject all sessions belonging to a deactivated account.
- Prevent self-deactivation and loss of the final active owner.
- Introduce explicit roles and a centralized permission vocabulary.
- Enforce permissions in Ash resources and services as well as web routes.
- Preserve actor labels and IDs in the administrator audit trail.
- Keep voters represented exclusively by `Member`, not `User`.
- Keep Oban Web read-only until separate mutable operational controls are approved.

## Non-goals

- Voter/member login accounts.
- Member self-service or converting a member into an administrator automatically.
- Organizations, tenants, or organization-scoped roles.
- Custom role builders or arbitrary per-user permission lists.
- SAML, OIDC, SCIM, LDAP, or enterprise identity-provider provisioning.
- Multi-factor authentication in the first iteration.
- Deleting administrator records or erasing their audit attribution.
- Allowing an owner to inspect or set another user's password.
- Restoring an unknown password; password reset remains the recovery mechanism.
- Making Oban Web writable in the initial role implementation.

## Terminology

### User or administrator account

A `Polly.Accounts.User` that authenticates into the protected administration application.

### Member

A `Polly.Members.Member` that may belong to a poll electorate and vote through a private access grant. A member does not authenticate into the administrator application.

### Owner

An active user who may manage administrator accounts, roles, invitations, and all ordinary Polly functionality.

### Administrator

An active user who manages members, polls, electorates, access, invitations, and results but cannot manage owners or administrator accounts.

### Auditor

An active read-only user who may inspect non-secret poll configuration, aggregate results, result exports, and audit history. Auditors cannot view raw private access tokens or credential-bearing access-link exports.

### Operator

An active operational user who may inspect invitation delivery status and the read-only Oban dashboard. Operator access does not imply poll configuration or administrator-management permission.

### Active owner

A user whose role is `:owner` and whose account status is `:active`. At least one must always exist after role enforcement is enabled.

## Current-state risks

- Any authenticated user satisfies the current `actor_present()` policies.
- Controller authentication only checks that `current_user` is a `User`.
- LiveView authentication only checks that a current user assign exists.
- Oban Web grants read-only access to every authenticated account.
- Stored authentication tokens can keep a deactivated account signed in unless subject loading and session checks enforce account status.
- There is no protected way to delegate account provisioning.
- A mistaken future deactivation or role change could lock every operator out.

## Proposed user model

### Role enum

Add:

```elixir
defmodule Polly.Accounts.User.Role do
  use Ash.Type.Enum, values: [:owner, :administrator, :auditor, :operator]
end
```

Add a non-null public `role` attribute to `User`.

### Status enum

Add:

```elixir
defmodule Polly.Accounts.User.Status do
  use Ash.Type.Enum, values: [:active, :disabled]
end
```

Add these attributes:

| Attribute | Type | Default | Purpose |
| --- | --- | --- | --- |
| `role` | role enum | `administrator` | Authorization role |
| `status` | status enum | `active` | Whether authentication and sessions are allowed |
| `disabled_at` | UTC datetime, nullable | `nil` | Account lifecycle history |
| `last_signed_in_at` | UTC datetime, nullable | `nil` | Support and stale-account visibility |
| `inserted_at` | UTC datetime | generated | Account creation time |
| `updated_at` | UTC datetime | generated | Last account change |

Do not overload `confirmed_at` as an activity flag. Confirmation proves control of an email address; status controls permission to use the account.

Physical destroy actions remain unavailable. Audit events continue to reference stable user IDs and labels after deactivation.

## Administrator invitation model

Add `Polly.Accounts.AdministratorInvitation`, backed by `administrator_invitations`.

| Attribute | Type | Notes |
| --- | --- | --- |
| `id` | UUID | Primary key and signed-token subject |
| `email` | case-insensitive string | Normalized invited address |
| `role` | user role enum | Requested initial role |
| `status` | enum | `pending`, `accepted`, `revoked`, or `expired` |
| `invited_by_id` | UUID | Required owner relationship |
| `accepted_user_id` | UUID, nullable | Populated after acceptance |
| `expires_at` | UTC datetime | Required expiration boundary |
| `sent_at` | UTC datetime, nullable | Latest provider-accepted invitation |
| `send_count` | integer | Number of accepted send attempts |
| `revoked_at` | UTC datetime, nullable | Revocation history |
| `accepted_at` | UTC datetime, nullable | Acceptance history |
| timestamps | UTC datetime | Standard timestamps |

The invitation must not contain a raw password, raw invitation token, password-reset token, or authentication session token.

Only one effective pending invitation may exist for an email address. Enforce this through a serialized invitation service and the strongest practical database constraint supported by SQLite. Acceptance remains protected by the unique user email identity even if unexpected duplicate invitation rows exist.

Inviting an email that already belongs to a user returns an actionable error. Owners should reactivate a disabled account rather than create another identity.

## Invitation credential design

Invitation URLs are bearer credentials. Use a signed, time-limited token derived from the invitation ID and its persisted expiration boundary.

Requirements:

- the token is signed with a dedicated runtime secret or a purpose-separated derivation of `TOKEN_SIGNING_SECRET`;
- verification binds the token to the invitation ID and `expires_at` value;
- token comparison and signature verification use constant-time primitives where applicable;
- the raw token is generated deterministically at the final email boundary so Oban retries can send the same credential without persisting it;
- the database stores invitation state and expiry, not the raw bearer token;
- accepting, revoking, or expiring the invitation makes the URL unusable; and
- token values never enter job arguments, audit metadata, logs, telemetry, or exception context.

The invitation worker receives only:

```elixir
%{"invitation_id" => invitation.id}
```

If deterministic signing cannot be implemented safely with the application's existing cryptographic primitives, store only an encrypted credential using a dedicated encryption key. Do not fall back to storing a plaintext token.

## Invitation workflow

### Creation

An owner submits an email address and permitted initial role. The service:

1. verifies `:manage_administrators` permission;
2. normalizes the email;
3. rejects an existing user for that email;
4. rejects or supersedes an existing unexpired pending invitation according to an explicit resend flow;
5. creates the pending invitation with a bounded expiry, initially seven days;
6. inserts a durable invitation email job;
7. appends `administrator.invited`; and
8. commits the invitation, job, and audit event atomically.

The UI responds after queueing and does not wait for Resend.

Owners may invite `:administrator`, `:auditor`, or `:operator`. Only an owner may invite another `:owner`, and the UI must use an additional confirmation warning for that elevation.

### Email

Send an individualized multipart Touchpad-styled email containing:

- Polly/Touchpad identity;
- inviter identity;
- invited role in plain language;
- invitation expiration;
- the private account-setup link;
- warning not to forward the link; and
- plain-text fallback.

Use Polly's configured Resend/Swoosh mailer and a dedicated bounded Oban queue or the existing mailers queue. Provider acceptance is not proof of inbox delivery.

### Resend

Resend is explicit and permitted only for a pending, unexpired invitation. It creates a new delivery attempt and audit event but does not extend expiry silently. The owner may choose **Renew invitation** to revoke the old invitation and create a new seven-day invitation with a new ID and credential.

### Revocation and expiry

An owner may revoke a pending invitation. Revocation is final. Expiration may be calculated from `expires_at` at read/verification time and optionally persisted by a maintenance job. Neither state creates a user.

### Acceptance

The public setup route verifies the signed invitation before showing an account form. The recipient enters and confirms a password; the email and role are read-only and derived from the invitation.

Inside one transaction, acceptance:

1. reloads the invitation;
2. requires `pending` status and future expiry;
3. verifies the signed credential;
4. rechecks that no user has the email;
5. creates a user with the invitation role and `status: :active`;
6. hashes the recipient-supplied password;
7. sets `confirmed_at` because the valid private invitation proves email control;
8. marks the invitation accepted and links `accepted_user_id`;
9. appends `administrator.invitation_accepted`; and
10. commits before signing the new user in.

Concurrent acceptance attempts may create only one user. The invitation state identity and unique user email constraint are final guards.

The ordinary public registration route remains disabled.

## Account lifecycle actions

Expose focused Ash actions or an `Polly.Accounts.Administrators` service rather than generic unrestricted updates:

```elixir
Administrators.change_role(target, role, actor)
Administrators.disable(target, actor)
Administrators.enable(target, actor)
Administrators.resend_invitation(invitation, actor)
Administrators.revoke_invitation(invitation, actor)
```

### Disable

Disabling an account:

- requires `:manage_administrators`;
- rejects self-deactivation;
- rejects disabling the final active owner;
- sets `status: :disabled` and `disabled_at`;
- revokes or removes all stored authentication and remember-me tokens for that user;
- causes existing LiveView sessions and controller requests to redirect to sign-in on their next authenticated interaction; and
- appends `administrator.disabled`.

### Enable

Enabling an account:

- requires `:manage_administrators`;
- sets `status: :active` and clears `disabled_at`;
- does not create a session;
- does not bypass email confirmation; and
- appends `administrator.enabled`.

A newly re-enabled user signs in normally or uses password reset.

### Change role

Changing a role:

- requires `:manage_administrators`;
- rejects demoting the final active owner;
- rejects self-demotion when the actor is the final active owner;
- updates existing sessions on their next request because authorization reads the current user record;
- revokes stored tokens if immediate privilege reduction cannot otherwise be guaranteed; and
- appends `administrator.role_changed` with old and new roles.

Role elevation to owner requires explicit confirmation in the UI.

### Email changes

Changing administrator email addresses is deferred. It requires reconfirmation, collision handling, session invalidation, and audit-label policy. The initial management UI directs owners to invite the correct address and disable the incorrect account.

## Final-owner protection

Polly must always retain at least one active owner.

The following operations invoke the same domain invariant:

- disabling an owner;
- demoting an owner;
- any future deletion or anonymization action; and
- bulk account changes.

The check and mutation run inside one repository transaction. For SQLite's single-writer deployment, the transaction serializes writes; the implementation must still test racing requests. UI counts are advisory and never the enforcement boundary.

There may be multiple owners. The product should encourage at least two for recovery, but it must not require two.

No “force” parameter may bypass final-owner protection through a public controller or LiveView. Emergency recovery uses a documented release task executed by an infrastructure operator with database access.

## Permission model

Create a centralized module such as `Polly.Accounts.Authorization`:

```elixir
Authorization.allowed?(user, permission)
Authorization.authorize(user, permission)
```

Permissions are stable atoms owned by application code, not user-defined strings:

- `:manage_administrators`
- `:manage_members`
- `:manage_polls`
- `:manage_electorates`
- `:manage_access_grants`
- `:send_invitations`
- `:view_results`
- `:publish_results`
- `:export_results`
- `:export_access_links`
- `:view_audit`
- `:view_jobs`
- `:operate_jobs` (deferred)

Disabled users have no permissions regardless of role.

### Initial role matrix

| Permission | Owner | Administrator | Auditor | Operator |
| --- | :---: | :---: | :---: | :---: |
| Manage administrators | Yes | No | No | No |
| Manage members | Yes | Yes | No | No |
| Manage polls/options | Yes | Yes | No | No |
| Manage electorates | Yes | Yes | No | No |
| View/copy/reissue private access links | Yes | Yes | No | No |
| Send voter invitations | Yes | Yes | No | No |
| View aggregate results | Yes | Yes | Yes | No |
| Close/publish results | Yes | Yes | No | No |
| Export aggregate results | Yes | Yes | Yes | No |
| Export credential-bearing access links | Yes | Yes | No | No |
| View audit history | Yes | No | Yes | No |
| View invitation delivery status | Yes | Yes | Yes | Yes |
| View read-only Oban Web | Yes | No | No | Yes |
| Mutate jobs or queues | No | No | No | No |

The exact administrator/auditor visibility of member personal information should be confirmed before implementation. The conservative default is that auditors may see aggregate results and safe audit labels but not member email addresses or access credentials.

## Enforcement architecture

### Ash resources and services

Replace broad `actor_present()` policies on protected domain resources with action-specific permission checks. Examples:

- poll create/update/open/close/publish checks the relevant poll permission;
- member writes check `:manage_members`;
- eligibility and grant actions check electorate/access permissions;
- result reads and exports check result permissions;
- access-grant reads that expose raw tokens deny auditors and operators;
- audit-event reads check `:view_audit`; and
- administrator/invitation actions check `:manage_administrators`.

Service modules must call or inherit the same authorization boundary. `authorize?: false` is reserved for trusted worker internals after a previously authorized durable command and narrowly justified invariant queries.

### LiveViews

Extend `PollyWeb.LiveUserAuth` with permission-aware hooks, for example:

```elixir
on_mount {PollyWeb.LiveUserAuth, {:require_permission, :manage_polls}}
```

Each protected LiveView declares its required permission. Navigation hides unavailable destinations for usability, but direct navigation is still denied by the mount hook and underlying Ash policies.

Disabled users are signed out rather than shown a forbidden page.

### Controllers

Replace `RequireAdministrator`'s type-only check with active-account and permission-aware plugs. Result CSV export checks `:export_results`; a future access-link export checks `:export_access_links`.

Unauthenticated or disabled users redirect to sign-in. Authenticated users lacking a permission receive a consistent `403` page without leaking protected resource existence.

### Oban Web

Update `PollyWeb.ObanWebResolver`:

- owner and operator with `:view_jobs` receive `:read_only`;
- all other users receive `{:forbidden, "/admin"}`;
- disabled and anonymous users receive sign-in/forbidden behavior as appropriate; and
- nobody receives `:all` in this iteration.

If `:operate_jobs` is introduced later, use Oban Web's fine-grained resolver controls and append audit events for retry, cancel, delete, insert, pause, resume, stop, and scale actions. Do not map the entire operator role to `:all`.

### Navigation and layouts

Build the administrator navigation from permissions or conditionally render each link. Add **Administrators** for owners. Keep **Background jobs** visible only to users with `:view_jobs`.

The application should present “You do not have permission to access this area” rather than making a signed-in user appear logged out.

## Administrator management UI

Add:

```text
/admin/administrators
```

The page contains separate **Accounts** and **Pending invitations** sections.

### Account list

Display:

- email;
- role;
- active/disabled status;
- confirmed/unconfirmed state;
- last sign-in when available;
- created date; and
- actions permitted for the current owner.

Use stable DOM IDs for rows, role controls, disable/enable actions, invitation form, and confirmation dialogs.

Role changes, deactivation, owner invitations, and invitation revocation require explicit confirmation. The current actor's row clearly says **You**, and unsafe self-actions are absent or disabled with explanatory text.

### Invitation form

Use `<.form>` and `<.input>` with:

- email;
- role selector; and
- submit action **Send invitation**.

The form never includes a password field for the invited person.

### Pending invitation list

Display:

- invited email;
- requested role;
- inviter;
- sent/pending/failed delivery state;
- expiration;
- resend/renew action; and
- revoke action.

Do not display or copy the raw invitation URL in the administration UI.

## Authentication behavior

All authentication entry points require an active account:

- password sign-in;
- magic-link sign-in if retained;
- remember-me restoration;
- token/session subject loading; and
- password reset completion.

Password-reset requests should remain non-enumerating. A disabled account receives no active session even if a valid reset token exists. Whether disabled users receive reset email should be decided conservatively; the initial recommendation is to suppress delivery without revealing status.

Record `last_signed_in_at` only after successful authentication. This operational timestamp belongs on the user and must not be represented as an audit event for every login in the initial iteration.

## Audit trail

Add actions:

- `administrator.invited`
- `administrator.invitation_resent`
- `administrator.invitation_renewed`
- `administrator.invitation_revoked`
- `administrator.invitation_accepted`
- `administrator.enabled`
- `administrator.disabled`
- `administrator.role_changed`

Safe metadata may contain:

- old and new roles;
- invitation role;
- invitation expiration;
- delivery attempt count; and
- target administrator or invitation ID.

The audit target label may be the normalized administrator email because this is an administrator-only audit interface and existing user actor labels already contain email. Revisit redaction and retention before exposing audit data outside owners and auditors.

Audit metadata must never contain:

- passwords or hashes;
- invitation, confirmation, reset, remember-me, or session tokens;
- email body content;
- provider payloads; or
- authentication cookies.

Automated invitation delivery attempts remain operational delivery records rather than one administrator audit event per retry.

## Bootstrap and migration

### Existing users

The migration must not lock existing installations out. Backfill every existing user as:

```text
role = owner
status = active
```

Although this may temporarily create multiple owners, it preserves existing authority and lets owners deliberately assign least-privilege roles after deployment. New accounts default to `administrator` unless created from an invitation with another explicit role.

Add non-null constraints only after backfill.

### Bootstrap Mix task

Update `mix polly.admin.create` to create an owner by default or accept an explicit safe role flag:

```sh
POLLY_ADMIN_PASSWORD="..." mix polly.admin.create owner@example.com --role owner
```

The task remains an infrastructure recovery boundary, not a public workflow. It should refuse to print passwords or tokens and should clearly report whether confirmation remains required.

Add a documented emergency task that can promote an existing confirmed, active account to owner only from a trusted release shell. It must emit a security log and audit event when an actor can be attributed. It must not bypass unique email or corrupt invitation state.

## Implementation phases

Each phase must pass `mix precommit` and its phase-specific tests before the next phase begins. A phase is complete only when its exit criteria are satisfied; partially hiding unfinished behavior behind navigation is not completion.

### Phase 0 — Decisions and authorization inventory

**Status:** Complete.

#### Purpose

Resolve the product choices that affect schema or authorization and establish a regression baseline before changing access rules.

#### Scope

- Confirm the initial role matrix in this specification.
- Decide whether administrators may view audit history.
- Decide how much recipient information operators may see.
- Confirm the invitation expiry and post-acceptance sign-in behavior.
- Inventory every protected LiveView, controller, Ash action, context service, Oban dashboard route, and `authorize?: false` call.
- Map each boundary to one permission or a documented trusted-system exemption.
- Capture the current owner account IDs and verify at least one can authenticate in the target environment.

#### Decisions

- The initial role matrix above is accepted as the implementation baseline.
- Audit history is visible to owners and auditors, not administrators or operators.
- Operators may see delivery IDs, timestamps, queue state, attempt counts, and safe error codes. They may not see member names, recipient email addresses, message bodies, private access URLs, or provider payloads.
- Administrator invitations expire after seven days. Resending does not extend the expiry; renewing creates a new invitation.
- Invitation acceptance commits the new confirmed account and accepted invitation before immediately signing the recipient in.
- Password-reset requests for disabled accounts remain non-enumerating and do not send an email.
- Polly encourages two owners for operational recovery but enforces only one active owner as the invariant.
- Oban Web remains read-only. `:operate_jobs` stays in the vocabulary as an explicitly deferred permission and is granted to no role.

#### Maintained inventory

`Polly.Accounts.AuthorizationCoverage` records the intended permission or trusted-system exemption for current web entry points, Ash actions, context services, and authorization bypasses. `Polly.Accounts.AuthorizationCoverageTest` fails when an Ash action or literal `authorize?: false` call is added or removed without reviewing the inventory.

The inventory describes the destination for phase 3; it does not change current authorization behavior.

#### Production account capture and recovery verification

Account IDs are environment data and must not be committed to this repository. Before phase 1 is deployed, an infrastructure operator should open a remote IEx shell and perform the following read-only query:

```elixir
alias Polly.Accounts.User

User
|> Ash.Query.load([])
|> Ash.read!(authorize?: false)
|> Enum.map(&%{id: &1.id, email: to_string(&1.email), confirmed_at: &1.confirmed_at})
```

Record the confirmed account IDs in the deployment runbook or password manager, then verify that at least one of those accounts can sign in. Do not paste this output into source control or CI logs.

Until phase 1 adds role and status fields, every existing `User` is effectively an administrator and there is no owner record to promote. The existing trusted recovery boundary is:

```sh
fly ssh console -a <app-name> -C "/app/bin/polly remote"
```

From that shell, use the documented account-creation procedure if no usable account remains. Phase 1 must add and test the dedicated owner promotion task before role enforcement can ship. Phase 0 recovery verification is intentionally read-only and does not authorize changing production account state.

#### Tests and verification

- Run the complete existing suite without authorization changes.
- Add a maintained permission-boundary inventory test, similar to the existing audit coverage inventory.
- Verify the production recovery procedure from a Fly remote shell without changing account state.

#### Exit criteria

- No role-matrix decision required by phases 1–5 remains unresolved.
- Every existing protected route/action has an intended permission.
- A tested owner-recovery approach is documented.

### Phase 1 — Lockout-safe user schema and bootstrap

**Status:** Implemented; production migration and sign-in smoke test pending.

#### Purpose

Introduce role and account status data without changing what existing users can do.

#### Scope

- Add `Polly.Accounts.User.Role` and `Polly.Accounts.User.Status` enums.
- Add `role`, `status`, `disabled_at`, `last_signed_in_at`, and timestamps to `User`.
- Backfill every existing user as `role: :owner` and `status: :active` before adding non-null constraints.
- Default new non-invited users to `:administrator` and `:active`.
- Update `mix polly.admin.create` with an explicit role option and owner-safe default.
- Add a trusted recovery task for promoting an existing confirmed, active user to owner.
- Display role/status in IEx inspection and documentation, but do not yet restrict application behavior by role.

#### Implementation notes

- Existing SQLite user rows are copied into the expanded schema as active owners before the original table is replaced.
- New registrations default to active administrators; the trusted `mix polly.admin.create` bootstrap command deliberately defaults to owner and accepts `--role`.
- `mix polly.admin.promote_owner EMAIL` promotes only an existing confirmed, active account and never creates credentials.
- The migration is intentionally irreversible because rolling it back would discard ownership and account-lifecycle history.
- No route, policy, navigation, or session behavior changes in this phase.

#### Explicitly deferred

- Role-based route or Ash policy enforcement.
- Account enable/disable UI.
- Invitations.
- Navigation changes.

#### Tests and verification

- Migration tests prove existing users become active owners.
- Fresh-account tests prove defaults are correct.
- Migration rollback refuses unsafe data loss.
- Mix-task tests cover valid roles, invalid roles, duplicates, and secret-safe output.
- A release migration smoke test verifies the current production owner can still sign in.

#### Exit criteria

- Production cannot be locked out by deploying the schema.
- Every existing administrator retains current access.
- At least one confirmed active owner and a recovery task are verified.

### Phase 2 — Account lifecycle and session safety

**Status:** Implemented; production migration and session smoke tests pending.

#### Purpose

Make account status authoritative and add safe domain operations before exposing management controls.

#### Scope

- Add `Polly.Accounts.Administrators` lifecycle services.
- Implement enable, disable, and role-change actions.
- Enforce self-deactivation protection.
- Enforce final-active-owner protection for disable and demotion.
- Run owner count checks and mutations in one repository transaction.
- Revoke stored authentication and remember-me tokens when disabling an account or reducing privileges where required.
- Require active status during password, magic-link, remember-me, session subject, and reset-token authentication flows.
- Make controller and LiveView authentication reject a disabled user on the next interaction.
- Record `administrator.enabled`, `administrator.disabled`, and `administrator.role_changed` audit events.

#### Implementation notes

- `Polly.Accounts.Administrators` is the only lifecycle mutation boundary and already requires an active owner actor.
- Disable, enable, and role changes reload the actor and target inside one SQLite write transaction before checking invariants.
- An SQLite trigger independently rejects any racing update that would remove the final active owner.
- Disabling an account and changing its role revoke all stored session and remember-me tokens for that subject.
- Password, sign-in-token, remember-me, session-subject, password-reset lookup, and reset completion actions require an active account.
- Polly does not currently configure a magic-link authentication strategy; if one is added later, its sign-in action must use the same active-account filter.
- Controller sessions are rejected after deactivation, and authenticated LiveViews reload the user before handling each client event.
- Successful interactive authentication records `last_signed_in_at`; enabling an account never creates a session.
- Lifecycle calls are idempotent: repeating an already-completed state change does not append another audit event.

#### Explicitly deferred

- Role permissions beyond `:manage_administrators` service checks.
- Administrator management UI.
- Invitations.

#### Tests and verification

- Domain tests cover enable, disable, role changes, and audit events.
- Self-deactivation and final-owner mutations fail without state or audit changes.
- Concurrent owner mutations cannot leave zero active owners.
- Disabled password and magic-link authentication fail safely.
- Existing browser and LiveView sessions stop working after deactivation.
- Re-enabled users must authenticate normally and receive no automatic session.

#### Exit criteria

- Disabled means disabled across every authentication path.
- Final-owner protection is enforced at the domain boundary under concurrency.
- Lifecycle changes are safely and exactly-once audited.

### Phase 3 — Central permissions and application-wide enforcement

**Status:** Implemented; production authorization smoke tests pending.

#### Purpose

Replace “any authenticated user” authorization with the documented role matrix.

#### Scope

- Add `Polly.Accounts.Authorization` and the stable permission vocabulary.
- Add reusable Ash policy checks for active status and permissions.
- Replace broad `actor_present()` policies with action-specific checks.
- Add permission-aware LiveView `on_mount` hooks.
- Replace the type-only controller plug with authentication plus required-permission plugs.
- Protect CSV results export with `:export_results`.
- Protect raw access grants and future access-link export with `:manage_access_grants` or `:export_access_links`.
- Restrict audit reads to the decided roles.
- Update Oban Web resolver so only owners/operators with `:view_jobs` receive `:read_only`.
- Add permission-aware navigation while retaining server-side enforcement.
- Review, minimize, and document every `authorize?: false` call.

#### Implementation notes

- `Polly.Accounts.Authorization` owns the stable permission vocabulary and fixed role matrix; disabled users always receive no permissions.
- `Polly.Accounts.Checks.HasPermission` applies that matrix to action-specific Ash policies for users, members, polls, options, electorates, access grants, ballots, selections, invitation deliveries, and audit events.
- Public access-grant resolution and ballot submission remain narrow trusted exceptions. Background invitation updates remain worker-only calls using the reviewed authorization bypass.
- Invitation delivery records are readable for delivery-status roles, while field policies redact recipient email addresses and provider identifiers from auditors and operators.
- Protected LiveViews declare one required permission or an explicit any-of set. Permission and active-account status are rechecked before every client event.
- The poll index becomes read-only for auditors and links directly to aggregate results. Mutation links and lifecycle controls are omitted when their permission is absent.
- Result CSV exports require `:export_results` in both the controller plug and export service.
- Administrator navigation is generated from permissions. No administrator-management link is added until its Phase 4 page exists.
- Oban Web grants only `:read_only` access and only to owners and operators; `:operate_jobs` remains unassigned.
- Signed-in users without permission receive a consistent forbidden response or are redirected to the safe administration overview with an explanatory flash.

#### Deployment safety

All users were backfilled as owners in phase 1, so deploying enforcement does not immediately remove existing access. Owners deliberately assign least-privilege roles only after this phase passes in production.

#### Tests and verification

- Table-driven tests cover every role/permission combination.
- Direct Ash calls prove denied actions fail independently of UI visibility.
- Direct LiveView and controller requests prove hidden links are not the security boundary.
- Disabled users receive no permissions regardless of role.
- Result exports allow owner, administrator, and auditor but deny operator.
- Raw access-grant reads deny auditor and operator.
- Oban Web remains read-only for every permitted role.

#### Exit criteria

- Every boundary in the phase 0 inventory has an enforced permission or documented system exemption.
- The full role matrix passes at domain and web layers.
- No role receives mutable Oban access.

### Phase 4 — Owner account-management interface

#### Purpose

Expose the already-tested lifecycle operations to owners before adding invitation complexity.

#### Scope

- Add `/admin/administrators` behind `:manage_administrators`.
- List existing accounts with email, role, status, confirmation, last sign-in, and created date.
- Add enable, disable, and change-role workflows with explicit confirmation.
- Label the current actor as **You**.
- Disable unsafe final-owner and self-actions with explanatory text.
- Add the owner-only **Administrators** navigation item.
- Show success and domain-error messages without leaking authentication details.
- Keep physical deletion and email changes unavailable.

#### Explicitly deferred

- Invitation form and pending invitations section.
- Bulk account changes.
- Custom roles.

#### Tests and verification

- Owners can mount and operate the page.
- Administrator, auditor, operator, disabled, and anonymous users cannot access it.
- Stable DOM IDs cover rows, role forms, status actions, and confirmations.
- UI actions exercise the domain service rather than direct generic Ash updates.
- Concurrent/stale UI actions surface final-owner errors correctly.
- Navigation visibility matches permissions.

#### Exit criteria

- Owners can safely manage every existing account lifecycle through Polly.
- No UI action can bypass the phase 2 invariants.
- Non-owners cannot reach the page or invoke its events.

### Phase 5 — Administrator invitations and account setup

#### Purpose

Replace routine shell provisioning with owner-managed, recipient-controlled account creation.

#### Scope

- Add `AdministratorInvitation` and its migration.
- Implement signed, expiring, purpose-separated invitation credentials.
- Implement owner-only create, resend, renew, and revoke services.
- Add durable invitation email jobs containing only `invitation_id`.
- Add Touchpad-styled multipart invitation email.
- Add public invitation verification and password-setup route.
- Atomically create an active, confirmed user and accept the invitation.
- Add the invitation form and pending invitations section to the management page.
- Add invitation lifecycle audit events and safe delivery status.
- Reject invitations for existing user emails and concurrent duplicate acceptance.

#### Tests and verification

- Valid acceptance creates exactly one confirmed user with the invited role.
- The inviter never provides or sees the password.
- Malformed, expired, revoked, accepted, and wrong-purpose tokens fail safely.
- Concurrent acceptance produces one user and one accepted invitation.
- Resend preserves expiry; renewal invalidates the old invitation.
- Jobs, database fields, audit events, logs, and telemetry contain no raw credential.
- Email tests cover intended recipient, HTML/plain text, expiry, and private-link warning.
- Owner invitation and elevation to owner require the specified confirmations.

#### Exit criteria

- Routine administrator creation no longer requires a shell command.
- Invitation delivery is durable and credential-safe.
- Acceptance is atomic, confirmed, and race-safe.

### Phase 6 — Hardening, rollout, and least privilege

#### Purpose

Validate the complete security model in production-like conditions and deliberately reduce existing users from temporary owner access.

#### Scope

- Run the complete authorization matrix against all routes and Ash actions.
- Test invitation and deactivation flows with the production mail adapter in a non-production environment.
- Verify Fly deployment, migration, rollback, remote recovery, and database backup procedures.
- Add operational metrics for invitations, disabled-session rejection, and authorization failures without sensitive metadata.
- Review audit retention and administrator email exposure.
- Review every owner account and assign the intended least-privilege role.
- Confirm at least two owners where operationally practical.
- Update README, deployment documentation, and operator runbooks.

#### Tests and verification

- Run `mix precommit` and security-focused end-to-end tests.
- Attempt every protected URL as each role, disabled user, and anonymous user.
- Verify old sessions fail after disable and privilege reduction.
- Confirm owner recovery from a Fly remote shell against a restored backup.
- Capture logs during invite/setup flows and scan for credentials.

#### Exit criteria

- Production roles match actual responsibilities.
- Recovery and rollback are documented and tested.
- No known authorization boundary relies solely on UI state.
- The feature specification may be marked implemented.

### Phase 7 — Mutable operational controls (deferred)

This phase is not part of the initial administrator-management implementation. Oban Web remains read-only until Polly has a concrete operational need.

Before enabling any mutation:

- define `:operate_jobs` separately from `:view_jobs`;
- select individual permitted actions rather than returning `:all`;
- audit retry, cancel, delete, insert, pause, resume, stop, and scale operations;
- account for the external email side effect of retrying invitation jobs; and
- add action-specific authorization and concurrency tests.

### Phase dependency summary

```text
Phase 0: decisions and inventory
   ↓
Phase 1: schema and owner bootstrap
   ↓
Phase 2: lifecycle and session invalidation
   ↓
Phase 3: permission enforcement
   ↓
Phase 4: owner management UI
   ↓
Phase 5: invitations and setup
   ↓
Phase 6: production hardening and least privilege

Phase 7: mutable operations — deferred and separately approved
```

Avoid deploying phase 3 restrictions before phase 1 backfill and phase 2 recovery/lifecycle protections are verified.

## Testing strategy

### User and invitation domain tests

- Existing migrated users are active owners.
- New invitation acceptance creates an active, confirmed user with the invited role.
- An inviter never supplies or receives the accepted password.
- Expired, revoked, accepted, malformed, and wrong-purpose tokens are rejected.
- Invitation tokens do not appear in database fields, jobs, audit events, logs, or telemetry.
- Concurrent acceptance creates exactly one user.
- Existing user emails cannot be invited.
- Resend preserves expiry; renewal revokes the old invitation.
- Deactivation revokes authentication tokens and blocks all authentication strategies.
- Reactivation does not create a session or bypass confirmation.
- Self-deactivation is rejected.
- Disabling or demoting the final active owner is rejected.
- Concurrent final-owner mutations cannot leave zero active owners.

### Authorization matrix tests

For every permission, test owner, administrator, auditor, operator, disabled, and anonymous actors. Cover:

- Ash read and mutation actions;
- context services;
- LiveView mounts and events;
- controller downloads;
- audit history;
- raw access-grant reads;
- invitation status; and
- Oban Web resolver access.

Tests must prove that hiding navigation is not the only boundary by directly calling routes and domain actions.

### LiveView tests

- Owners can list accounts and pending invitations.
- Non-owners cannot mount administrator management.
- Invitation forms use stable IDs and never ask for a password.
- Role and disable confirmations describe consequences.
- Final-owner and self-action controls are disabled with explanations.
- Resend, renew, revoke, enable, disable, and role changes update the page.
- Navigation reflects permissions without exposing secret-bearing destinations.

### Controller and authentication tests

- Disabled sessions redirect to sign-in on the next request.
- Active users without permission receive `403` rather than authentication redirects.
- Result exports allow owner, administrator, and auditor only.
- Credential-bearing access exports deny auditors and operators.
- Return-to behavior never bypasses the permission check after sign-in.
- Password reset and confirmation flows cannot reactivate disabled users.

### Audit and privacy tests

- Every administrator lifecycle action creates one attributed event.
- Failed actions create no success event.
- Events contain role transitions but no credentials.
- Invitation jobs contain only invitation IDs.
- Captured logs contain no raw invitation or authentication tokens.

## Acceptance criteria

- Owners can invite, view, renew, resend, and revoke administrator invitations.
- Invitees set their own password through an expiring private link.
- Accepting an invitation creates a confirmed, active account with the assigned role.
- Owners can enable, disable, and change roles without deleting account history.
- Polly cannot be left without an active owner through application actions or races.
- Disabled users cannot sign in or continue using stored sessions.
- Owner, administrator, auditor, and operator permissions match the documented matrix.
- Ash actions and services enforce authorization independently of the UI.
- Controller exports and Oban Web enforce specific permissions.
- Oban Web remains read-only for every role.
- Administrator lifecycle changes are safely audited without credentials.
- Existing installations retain access after migration.
- `User` and `Member` remain distinct concepts and resources.

## Open decisions

1. Should administrators be allowed to view audit history, or should it remain owner/auditor-only?
2. Should operators see all invitation recipient emails or only delivery IDs and aggregate state?
3. Should invitation expiry be fixed at seven days or configurable per installation?
4. Should accepting an invitation sign the user in immediately or require a normal first sign-in?
5. Should disabled accounts receive password-reset emails that remain unusable until reactivation?
6. Is an installation-level second-owner recommendation sufficient, or should production require two owners before allowing demotion?
7. Which future Oban actions, if any, should `:operate_jobs` permit?

## Related documentation

- [Administrator audit trail specification](admin-audit-trail-spec.md)
- [Email invitation delivery specification](email-invitation-delivery-spec.md)
- [Access-link CSV export specification](access-link-csv-export-spec.md)
- [CSV results export specification](csv-results-export-spec.md)
