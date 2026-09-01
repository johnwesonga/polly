defmodule Polly.Polls.Invitations do
  @moduledoc "Queues private voting invitations and reports recipient readiness."

  require Ash.Query

  alias Polly.Polls.{AccessGrant, Ballot, Eligibility, InvitationDelivery, InvitationWorker, Poll}

  def preview(%Poll{} = poll, actor) do
    recipients = recipients(poll, actor)

    %{
      recipients: recipients,
      ready_count: Enum.count(recipients, &(&1.state == :ready)),
      skipped_count: Enum.count(recipients, &(&1.state != :ready)),
      counts: Enum.frequencies_by(recipients, & &1.state)
    }
  end

  def enqueue_bulk(%Poll{status: :open} = poll, actor) do
    operation_id = Ash.UUID.generate()
    preview = preview(poll, actor)
    ready = Enum.filter(preview.recipients, &(&1.state == :ready))

    {:ok, deliveries} =
      Polly.Repo.transaction(fn ->
        deliveries = Enum.map(ready, &queue(&1, actor, operation_id, :initial))

        Polly.Audit.append!(%{
          action: "poll.invitations_enqueued",
          actor: actor,
          operation_id: operation_id,
          target: %{type: "poll", id: poll.id, label: poll.title},
          poll_id: poll.id,
          metadata: %{
            queued_count: length(deliveries),
            skipped_count: preview.skipped_count,
            request_kind: "bulk"
          }
        })

        deliveries
      end)

    {:ok, deliveries}
  rescue
    error -> {:error, error}
  end

  def enqueue_bulk(%Poll{}, _actor), do: {:error, :poll_not_open}

  def enqueue_one(%AccessGrant{} = grant, actor, kind \\ :initial)
      when kind in [:initial, :resend] do
    poll = Ash.get!(Poll, grant.poll_id, actor: actor)

    case Enum.find(recipients(poll, actor), &(&1.grant && &1.grant.id == grant.id)) do
      %{state: :ready} = recipient ->
        enqueue_recipient(poll, recipient, actor, kind)

      %{state: :already_invited} = recipient when kind == :resend ->
        enqueue_recipient(poll, recipient, actor, kind)

      %{state: state} ->
        {:error, state}

      nil ->
        {:error, :not_eligible}
    end
  end

  defp enqueue_recipient(poll, recipient, actor, kind) do
    operation_id = Ash.UUID.generate()

    {:ok, delivery} =
      Polly.Repo.transaction(fn ->
        delivery = queue(recipient, actor, operation_id, kind)

        Polly.Audit.append!(%{
          action: "poll.invitations_enqueued",
          actor: actor,
          operation_id: operation_id,
          target: %{type: "poll", id: poll.id, label: poll.title},
          poll_id: poll.id,
          metadata: %{queued_count: 1, skipped_count: 0, request_kind: Atom.to_string(kind)}
        })

        delivery
      end)

    {:ok, delivery}
  rescue
    error -> {:error, error}
  end

  defp queue(recipient, actor, operation_id, kind) do
    dedupe_key = dedupe_key(recipient.grant.id, operation_id, kind)

    delivery =
      Ash.create!(
        InvitationDelivery,
        %{
          poll_id: recipient.eligibility.poll_id,
          member_id: recipient.member.id,
          access_grant_id: recipient.grant.id,
          requested_by_id: actor.id,
          operation_id: operation_id,
          kind: kind,
          dedupe_key: dedupe_key,
          recipient_email: recipient.member.email,
          credential_version: recipient.grant.credential_version
        },
        action: :queue,
        actor: actor
      )

    %{delivery_id: delivery.id}
    |> InvitationWorker.new()
    |> Oban.insert!()

    delivery
  end

  defp recipients(poll, actor) do
    deliveries_by_grant = deliveries_by_grant(poll.id, actor)
    ballots = ballot_member_ids(poll.id, actor)

    grants_by_member =
      AccessGrant
      |> Ash.Query.filter(poll_id == ^poll.id and is_nil(revoked_at))
      |> Ash.Query.select([
        :id,
        :poll_id,
        :member_id,
        :credential_version,
        :revoked_at,
        :expires_at,
        :inserted_at
      ])
      |> Ash.Query.sort(inserted_at: :desc)
      |> Ash.read!(actor: actor)
      |> Enum.reduce(%{}, &Map.put_new(&2, &1.member_id, &1))

    Eligibility
    |> Ash.Query.filter(poll_id == ^poll.id)
    |> Ash.Query.load(:member)
    |> Ash.read!(actor: actor)
    |> Enum.sort_by(&String.downcase(&1.member.name))
    |> Enum.map(fn eligibility ->
      member = eligibility.member
      grant = Map.get(grants_by_member, member.id)
      delivery_info = grant && Map.get(deliveries_by_grant, grant.id)
      delivery = delivery_info && delivery_info.latest

      %{
        eligibility: eligibility,
        member: member,
        grant: grant,
        delivery: delivery,
        latest_accepted_at: delivery_info && delivery_info.latest_accepted_at,
        state: state(poll, member, grant, delivery, ballots)
      }
    end)
  end

  defp state(%Poll{status: status}, _member, _grant, _delivery, _ballots) when status != :open,
    do: :poll_not_open

  defp state(_poll, %{active: false}, _grant, _delivery, _ballots), do: :inactive_member

  defp state(_poll, %{email: email}, _grant, _delivery, _ballots) when email in [nil, ""],
    do: :missing_email

  defp state(_poll, member, _grant, _delivery, ballots) when is_map_key(ballots, member.id),
    do: :already_voted

  defp state(_poll, _member, nil, _delivery, _ballots), do: :missing_grant

  defp state(_poll, _member, grant, delivery, _ballots) do
    cond do
      grant.revoked_at ->
        :revoked_grant

      grant.expires_at && DateTime.compare(grant.expires_at, DateTime.utc_now()) != :gt ->
        :expired_grant

      match?(%InvitationDelivery{}, delivery) ->
        :already_invited

      true ->
        :ready
    end
  end

  defp deliveries_by_grant(poll_id, actor) do
    InvitationDelivery
    |> Ash.Query.filter(poll_id == ^poll_id)
    |> Ash.Query.sort(inserted_at: :desc)
    |> Ash.read!(actor: actor)
    |> Enum.reduce(%{}, fn delivery, deliveries ->
      Map.update(
        deliveries,
        delivery.access_grant_id,
        %{latest: delivery, latest_accepted_at: delivery.accepted_at},
        fn info ->
          %{info | latest_accepted_at: info.latest_accepted_at || delivery.accepted_at}
        end
      )
    end)
  end

  defp ballot_member_ids(poll_id, actor) do
    Ballot
    |> Ash.Query.filter(poll_id == ^poll_id)
    |> Ash.read!(actor: actor)
    |> Map.new(&{&1.member_id, true})
  end

  defp dedupe_key(grant_id, _operation_id, :initial), do: "initial:#{grant_id}"
  defp dedupe_key(grant_id, operation_id, :resend), do: "resend:#{operation_id}:#{grant_id}"
end
