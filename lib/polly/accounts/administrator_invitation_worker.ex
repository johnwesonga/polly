defmodule Polly.Accounts.AdministratorInvitationWorker do
  @moduledoc "Durably delivers an administrator setup invitation using only its persisted ID."

  use Oban.Worker, queue: :mailers, max_attempts: 5

  alias Polly.Accounts.{
    AdministratorInvitation,
    AdministratorInvitationEmail,
    AdministratorInvitationToken,
    User
  }

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"invitation_id" => id}} = job) do
    invitation = Ash.get!(AdministratorInvitation, id, authorize?: false)

    cond do
      invitation.status != :pending ->
        :ok

      not DateTime.after?(invitation.expires_at, DateTime.utc_now()) ->
        Ash.update!(invitation, %{}, action: :expire, authorize?: false)
        :ok

      true ->
        deliver(invitation, job)
    end
  end

  defp deliver(invitation, job) do
    invitation =
      Ash.update!(invitation, %{delivery_status: :sending, last_error_code: nil},
        action: :record_delivery,
        authorize?: false
      )

    inviter = Ash.get!(User, invitation.invited_by_id, authorize?: false)
    token = AdministratorInvitationToken.sign(invitation)

    url =
      PollyWeb.Endpoint.url() <>
        "/administrator-invitations/#{invitation.id}/setup?token=#{URI.encode_www_form(token)}"

    email =
      invitation
      |> AdministratorInvitationEmail.build(inviter.email, url)
      |> Swoosh.Email.put_provider_option(
        :idempotency_key,
        "administrator-invitation-#{invitation.id}-#{invitation.send_count + 1}"
      )

    case Polly.Mailer.deliver(email) do
      {:ok, _response} ->
        Ash.update!(
          invitation,
          %{
            delivery_status: :sent,
            sent_at: now(),
            send_count: invitation.send_count + 1,
            last_error_code: nil
          },
          action: :record_delivery,
          authorize?: false
        )

        :ok

      {:error, reason} when job.attempt >= job.max_attempts ->
        Ash.update!(invitation, %{delivery_status: :failed, last_error_code: error_code(reason)},
          action: :record_delivery,
          authorize?: false
        )

        :ok

      {:error, reason} ->
        Ash.update!(invitation, %{delivery_status: :queued, last_error_code: error_code(reason)},
          action: :record_delivery,
          authorize?: false
        )

        {:error, error_code(reason)}
    end
  end

  defp error_code(%Req.TransportError{reason: :timeout}), do: "timeout"
  defp error_code(_reason), do: "provider_error"

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)
end
