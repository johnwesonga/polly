defmodule Polly.Accounts.AdministratorInvitationEmail do
  @moduledoc "Builds Touchpad-styled multipart administrator invitation email."

  import Swoosh.Email

  alias Polly.Accounts.AdministratorInvitation

  def build(%AdministratorInvitation{} = invitation, inviter_email, setup_url) do
    role = invitation.role |> to_string() |> String.capitalize()
    expiry = Calendar.strftime(invitation.expires_at, "%B %-d, %Y at %-I:%M %p UTC")

    new()
    |> to(to_string(invitation.email))
    |> from(Application.fetch_env!(:polly, :invitation_from))
    |> subject("You’re invited to administer Touchpad")
    |> text_body(text_body(inviter_email, role, expiry, setup_url))
    |> html_body(html_body(inviter_email, role, expiry, setup_url))
  end

  defp text_body(inviter, role, expiry, url) do
    """
    You’re invited to Touchpad

    #{inviter} invited you to join as #{role}.
    Set up your account: #{url}

    This private link expires #{expiry}. Do not forward or share it.
    """
  end

  defp html_body(inviter, role, expiry, url) do
    inviter = escape(inviter)
    role = escape(role)
    expiry = escape(expiry)
    url = escape(url)

    """
    <!doctype html><html lang="en"><body style="margin:0;padding:32px 16px;background:#ECF1EF;color:#0B1F33;font-family:Inter,Arial,sans-serif">
    <table role="presentation" width="100%"><tr><td align="center"><table role="presentation" width="100%" style="max-width:560px"><tr><td style="padding:0 4px 18px;font-size:22px;font-weight:800;letter-spacing:1.5px;text-transform:uppercase">Touchpad</td></tr><tr><td style="padding:38px;background:#fff;border:1px solid #D4DDDA;border-top:4px solid #E8491D;border-radius:16px"><p style="color:#5C7080;font-size:11px;font-weight:700;letter-spacing:1.4px;text-transform:uppercase">Administrator invitation</p><h1 style="font-size:30px">You’re invited</h1><p style="line-height:1.65">#{inviter} invited you to join Touchpad as <strong>#{role}</strong>.</p><p><a href="#{url}" style="display:inline-block;padding:14px 24px;background:#E8491D;color:#fff;border-radius:10px;text-decoration:none;font-weight:700">Set up your account →</a></p><p style="padding:16px 18px;background:#FCE4DA;border-radius:10px;color:#8F3218;font-size:13px"><strong>Keep this link private.</strong><br>Do not forward or share it. It expires #{expiry}.</p></td></tr></table></td></tr></table>
    </body></html>
    """
  end

  defp escape(value), do: value |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()
end
