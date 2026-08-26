defmodule Polly.Accounts.User.Senders.SendPasswordResetEmail do
  @moduledoc """
  Sends a password reset email
  """

  use AshAuthentication.Sender
  use PollyWeb, :verified_routes

  import Swoosh.Email

  alias Polly.Mailer

  @impl true
  def send(user, token, _) do
    from = Application.fetch_env!(:polly, :invitation_from)

    new()
    # TODO: Replace with your email
    |> from(from)
    |> to(to_string(user.email))
    |> subject("Reset your password")
    |> html_body(body(token: token))
    |> Mailer.deliver!()
  end

  defp body(params) do
    url = url(~p"/password-reset/#{params[:token]}")

    """
    <p>Click this link to reset your password:</p>
    <p><a href="#{url}">#{url}</a></p>
    """
  end
end
