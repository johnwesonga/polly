defmodule Polly.Polls.InvitationEmail do
  @moduledoc "Builds individualized poll invitation emails."

  import Swoosh.Email

  alias Polly.Members.Member
  alias Polly.Polls.{Poll, SelectionRules}

  def build(%Poll{} = poll, %Member{} = member, token, recipient_email)
      when is_binary(token) do
    url = PollyWeb.Endpoint.url() <> "/polls/#{poll.id}/vote/#{token}"
    from = Application.fetch_env!(:polly, :invitation_from)

    new()
    |> to({member.name, recipient_email})
    |> from(from)
    |> subject("Voting is open: #{poll.title}")
    |> text_body(text_body(poll, member, url))
    |> html_body(html_body(poll, member, url))
  end

  defp text_body(poll, member, url) do
    selection_rule = SelectionRules.summary(poll)

    """
    Hello #{member.name},

    You are invited to vote in “#{poll.title}”.
    Selection rule: #{selection_rule}.

    Cast your vote: #{url}

    This voting link is personal to you. Do not forward or share it.
    Once submitted, your vote is final.
    """
  end

  defp html_body(poll, member, url) do
    name = escape(member.name)
    title = escape(poll.title)
    selection_rule = poll |> SelectionRules.summary() |> escape()
    safe_url = escape(url)

    """
    <!doctype html>
    <html lang="en">
      <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <meta name="color-scheme" content="light">
        <meta name="supported-color-schemes" content="light">
        <title>Voting is open: #{title}</title>
      </head>
      <body style="margin:0; padding:0; background-color:#ECF1EF; color:#0B1F33; font-family:Inter, Arial, sans-serif; -webkit-text-size-adjust:100%;">
        <div style="display:none; max-height:0; overflow:hidden; opacity:0; color:transparent;">
          Your private voting link for #{title} is ready.
        </div>
        <table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" bgcolor="#ECF1EF" style="width:100%; background-color:#ECF1EF;">
          <tr>
            <td align="center" style="padding:32px 16px;">
              <table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" style="width:100%; max-width:560px;">
                <tr>
                  <td style="padding:0 4px 18px;">
                    <table role="presentation" cellpadding="0" cellspacing="0" border="0">
                      <tr>
                        <td width="30" height="30" align="center" valign="middle" bgcolor="#0B1F33" style="width:30px; height:30px; border-radius:8px; color:#E8491D; font-size:18px; font-weight:700; line-height:30px;">□</td>
                        <td style="padding-left:10px; color:#0B1F33; font-size:22px; font-weight:800; letter-spacing:1.5px; text-transform:uppercase;">Touchpad</td>
                      </tr>
                    </table>
                  </td>
                </tr>
                <tr>
                  <td bgcolor="#FFFFFF" style="background-color:#FFFFFF; border:1px solid #D4DDDA; border-radius:16px; overflow:hidden;">
                    <div style="height:4px; background-color:#E8491D; font-size:0; line-height:0;">&nbsp;</div>
                    <table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0">
                      <tr>
                        <td style="padding:38px 38px 34px;">
                          <p style="margin:0 0 14px; color:#5C7080; font-size:11px; font-weight:700; letter-spacing:1.4px; text-transform:uppercase;">Private poll invitation</p>
                          <h1 style="margin:0 0 20px; color:#0B1F33; font-size:30px; line-height:1.15; letter-spacing:-0.4px;">Voting is open</h1>
                          <p style="margin:0 0 12px; color:#0B1F33; font-size:16px; line-height:1.65;">Hello #{name},</p>
                          <p style="margin:0 0 12px; color:#1B3A55; font-size:16px; line-height:1.65;">You are invited to vote in <strong style="color:#0B1F33;">#{title}</strong>.</p>
                          <p style="margin:0 0 26px; color:#1B3A55; font-size:14px; line-height:1.55;"><strong style="color:#0B1F33;">Selection rule:</strong> #{selection_rule}.</p>
                          <table role="presentation" cellpadding="0" cellspacing="0" border="0" style="margin:0 0 26px;">
                            <tr>
                              <td bgcolor="#E8491D" style="background-color:#E8491D; border-radius:10px;">
                                <a href="#{safe_url}" style="display:inline-block; padding:14px 24px; color:#FFFFFF; font-size:15px; font-weight:700; line-height:20px; text-decoration:none;">Cast your vote&nbsp; →</a>
                              </td>
                            </tr>
                          </table>
                          <table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" bgcolor="#FCE4DA" style="width:100%; background-color:#FCE4DA; border-radius:10px;">
                            <tr>
                              <td style="padding:16px 18px; color:#8F3218; font-size:13px; line-height:1.55;">
                                <strong style="color:#6F2713;">Keep this link private.</strong><br>
                                It is personal to you and must not be forwarded or shared. Once submitted, your vote is final.
                              </td>
                            </tr>
                          </table>
                        </td>
                      </tr>
                    </table>
                  </td>
                </tr>
                <tr>
                  <td style="padding:20px 6px 0; color:#5C7080; font-size:12px; line-height:1.6; text-align:center;">
                    If the button does not work, copy and paste this private link into your browser:<br>
                    <a href="#{safe_url}" style="color:#1B3A55; text-decoration:underline; word-break:break-all;">#{safe_url}</a>
                  </td>
                </tr>
              </table>
            </td>
          </tr>
        </table>
      </body>
    </html>
    """
  end

  defp escape(value), do: value |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()
end
