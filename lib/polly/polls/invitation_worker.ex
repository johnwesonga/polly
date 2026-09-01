defmodule Polly.Polls.InvitationWorker do
  @moduledoc "Delivers a queued private poll invitation after revalidating access."

  use Oban.Worker, queue: :mailers, max_attempts: 5

  require Ash.Query

  alias Polly.Polls.{AccessGrant, Ballot, InvitationDelivery, InvitationEmail, Poll}

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"delivery_id" => delivery_id}} = job) do
    delivery =
      InvitationDelivery
      |> Ash.get!(delivery_id, authorize?: false)
      |> Ash.load!([:member, :access_grant], authorize?: false)

    cond do
      delivery.status in [:accepted, :cancelled] ->
        :ok

      reason = cancellation_reason(delivery) ->
        cancel(delivery, reason)

      true ->
        deliver(delivery, job)
    end
  end

  defp cancellation_reason(delivery) do
    poll = Ash.get!(Poll, delivery.poll_id, authorize?: false)

    cond do
      poll.status != :open -> "poll_not_open"
      not delivery.member.active -> "member_inactive"
      delivery.member.email != delivery.recipient_email -> "recipient_changed"
      delivery.access_grant.revoked_at -> "grant_revoked"
      expired?(delivery.access_grant.expires_at) -> "grant_expired"
      ballot_exists?(delivery.poll_id, delivery.member_id) -> "already_voted"
      true -> nil
    end
  end

  defp deliver(delivery, job) do
    attempts = delivery.attempt_count + 1

    delivery =
      Ash.update!(
        delivery,
        %{status: :sending, attempt_count: attempts, last_error_code: nil},
        action: :record_attempt,
        authorize?: false
      )

    poll = Ash.get!(Poll, delivery.poll_id, authorize?: false)
    token = AccessGrant.derive_token_for_delivery(delivery.access_grant)

    email =
      InvitationEmail.build(
        poll,
        delivery.member,
        token,
        delivery.recipient_email
      )

    email = Swoosh.Email.put_provider_option(email, :idempotency_key, delivery.dedupe_key)

    case Polly.Mailer.deliver(email) do
      {:ok, response} ->
        Ash.update!(
          delivery,
          %{provider_message_id: provider_message_id(response), attempt_count: attempts},
          action: :accept,
          authorize?: false
        )

        :ok

      {:error, reason} when job.attempt >= job.max_attempts ->
        Ash.update!(
          delivery,
          %{attempt_count: attempts, last_error_code: error_code(reason)},
          action: :fail,
          authorize?: false
        )

        :ok

      {:error, reason} ->
        Ash.update!(
          delivery,
          %{status: :queued, attempt_count: attempts, last_error_code: error_code(reason)},
          action: :record_attempt,
          authorize?: false
        )

        {:error, error_code(reason)}
    end
  end

  defp cancel(delivery, reason) do
    Ash.update!(delivery, %{last_error_code: reason}, action: :cancel, authorize?: false)
    :ok
  end

  defp ballot_exists?(poll_id, member_id) do
    Ballot
    |> Ash.Query.filter(poll_id == ^poll_id and member_id == ^member_id)
    |> Ash.exists?(authorize?: false)
  end

  defp expired?(nil), do: false
  defp expired?(expires_at), do: DateTime.compare(expires_at, DateTime.utc_now()) != :gt

  defp provider_message_id(%{id: id}) when is_binary(id), do: id
  defp provider_message_id(%{"id" => id}) when is_binary(id), do: id
  defp provider_message_id(_response), do: nil

  defp error_code(%Req.TransportError{reason: :timeout}), do: "timeout"
  defp error_code(_reason), do: "provider_error"
end
