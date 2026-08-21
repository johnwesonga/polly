# First-release product decisions

This document closes the product questions identified during Phase 0. These
decisions are the contract for Polly's first complete polling flow. Revisit them
only in a later, explicitly scoped product iteration.

## Poll lifecycle

- A poll moves forward from `draft` to `open` to `closed`.
- A closed poll cannot be reopened.
- Publishing results is final; published results cannot be withdrawn.
- The first release has no separate archive state. Closed polls and their
  history are retained and may be hidden from the primary admin list with a
  filter later.

## Electorate and access

- The administrator must explicitly confirm the electorate for every poll.
  "Select all" may be provided as a convenience, but there is no implicit live
  roster eligibility.
- The first release supports selecting all members or individual members. It
  does not include reusable groups or segments.
- Links are delivered by copy and paste initially. CSV export and email delivery
  are deferred.
- Reissuing access revokes the previous grant and creates a new token. It does
  not delete or alter eligibility or ballot history. Because ballots are created
  lazily, there is no unsubmitted ballot to invalidate.
- Access grants do not expire by default, but can be revoked. A valid grant may
  be used to view published results after voting closes.

## Options and results

- Text options have a required label only. Descriptions and member-backed
  options are deferred.
- Options are ordered with move-up and move-down controls. Drag-and-drop is
  deferred.
- Options and eligibility are frozen when a poll opens.
- Equal vote totals are displayed as ties.

## Administration and deployment

- Every application user is an administrator in the first release. Public
  registration is disabled; administrators must be provisioned by an operator.
  Role-based administration is deferred.
- SQLite is the initial database target for a single-node, modest-volume
  deployment. Moving to multiple application nodes requires revisiting the
  database and PubSub architecture first.
