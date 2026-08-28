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
  def perform(%Oban.Job{args: %{"invitation_id" => id}}) do
    invitation = Ash.get!(AdministratorInvitation, id, authorize?: false)

    if invitation.status == :pending and
         DateTime.after?(invitation.expires_at, DateTime.utc_now()) do
      inviter = Ash.get!(User, invitation.invited_by_id, authorize?: false)
      token = AdministratorInvitationToken.sign(invitation)

      url =
        PollyWeb.Endpoint.url() <>
          "/administrator-invitations/#{id}/setup?token=#{URI.encode_www_form(token)}"

      case Polly.Mailer.deliver(
             AdministratorInvitationEmail.build(invitation, inviter.email, url)
           ) do
        {:ok, _response} ->
          Ash.update!(invitation, %{sent_at: now(), send_count: invitation.send_count + 1},
            action: :record_sent,
            authorize?: false
          )

          :ok

        {:error, reason} ->
          {:error, reason}
      end
    else
      :ok
    end
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)
end
