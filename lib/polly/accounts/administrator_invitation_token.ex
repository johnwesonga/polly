defmodule Polly.Accounts.AdministratorInvitationToken do
  @moduledoc "Signs purpose-separated, deterministic administrator invitation credentials."

  alias Polly.Accounts.AdministratorInvitation

  def sign(%AdministratorInvitation{} = invitation) do
    Plug.Crypto.MessageVerifier.sign(message(invitation), secret())
  end

  def valid?(%AdministratorInvitation{} = invitation, token) when is_binary(token) do
    Plug.Crypto.MessageVerifier.verify(token, secret()) == {:ok, message(invitation)}
  end

  def valid?(_invitation, _token), do: false

  defp message(invitation),
    do: "v1:#{invitation.id}:#{DateTime.to_iso8601(invitation.expires_at)}"

  defp secret do
    signing_secret = Application.fetch_env!(:polly, :token_signing_secret)
    :crypto.mac(:hmac, :sha256, signing_secret, "administrator-invitation:v1")
  end
end
