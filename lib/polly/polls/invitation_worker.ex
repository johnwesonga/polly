defmodule Polly.Polls.InvitationWorker do
  @moduledoc "Delivers a queued private poll invitation after revalidating access."

  use Oban.Worker, queue: :mailers, max_attempts: 5

  require Ash.Query

  alias Polly.Polls.{
    AccessGrant,
    Eligibility,
    InvitationDelivery,
    InvitationEmail,
    Participation,
    Poll
  }

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
      poll.status != :open ->
        "poll_not_open"

      not delivery.member.active ->
        "member_inactive"

      delivery.member.email != delivery.recipient_email ->
        "recipient_changed"

      delivery.credential_version != delivery.access_grant.credential_version ->
        "stale_credential"

      delivery.access_grant.revoked_at ->
        "grant_revoked"

      expired?(delivery.access_grant.expires_at) ->
        "grant_expired"

      not eligible?(delivery.poll_id, delivery.member_id) ->
        "not_eligible"

      Participation.submitted?(delivery.poll_id, delivery.member_id) ->
        "already_voted"

      reminder_inside_cooldown?(delivery) ->
        "reminder_cooldown"

      true ->
        nil
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

    email = build_email(delivery, poll, token)

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

  defp expired?(nil), do: false
  defp expired?(expires_at), do: DateTime.compare(expires_at, DateTime.utc_now()) != :gt

  defp eligible?(poll_id, member_id) do
    Eligibility
    |> Ash.Query.filter(poll_id == ^poll_id and member_id == ^member_id)
    |> Ash.exists?(authorize?: false)
  end

  defp reminder_inside_cooldown?(%InvitationDelivery{kind: kind}) when kind != :reminder,
    do: false

  defp reminder_inside_cooldown?(delivery) do
    cutoff =
      DateTime.add(DateTime.utc_now(), -reminder_cooldown_hours() * 60 * 60, :second)

    InvitationDelivery
    |> Ash.Query.filter(
      id != ^delivery.id and poll_id == ^delivery.poll_id and member_id == ^delivery.member_id and
        access_grant_id == ^delivery.access_grant_id and kind == :reminder and status == :accepted and
        accepted_at > ^cutoff
    )
    |> Ash.exists?(authorize?: false)
  end

  defp reminder_cooldown_hours do
    :polly |> Application.fetch_env!(:reminder_cooldown) |> Keyword.fetch!(:hours)
  end

  defp build_email(%InvitationDelivery{kind: :reminder} = delivery, poll, token) do
    InvitationEmail.build_reminder(poll, delivery.member, token, delivery.recipient_email)
  end

  defp build_email(delivery, poll, token) do
    InvitationEmail.build(poll, delivery.member, token, delivery.recipient_email)
  end

  defp provider_message_id(%{id: id}) when is_binary(id), do: id
  defp provider_message_id(%{"id" => id}) when is_binary(id), do: id
  defp provider_message_id(_response), do: nil

  defp error_code(%Req.TransportError{reason: :timeout}), do: "timeout"
  defp error_code(_reason), do: "provider_error"
end
