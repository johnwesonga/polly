defmodule Polly.Polls.InvitationEmail do
  @moduledoc "Builds individualized poll invitation emails."

  import Swoosh.Email

  alias Polly.Members.Member
  alias Polly.Polls.{AccessGrant, Poll}

  def build(%Poll{} = poll, %Member{} = member, %AccessGrant{} = grant, recipient_email) do
    url = PollyWeb.Endpoint.url() <> "/polls/#{poll.id}/vote/#{grant.token}"
    from = Application.fetch_env!(:polly, :invitation_from)

    new()
    |> to({member.name, recipient_email})
    |> from(from)
    |> subject("Voting is open: #{poll.title}")
    |> text_body(text_body(poll, member, url))
    |> html_body(html_body(poll, member, url))
  end

  defp text_body(poll, member, url) do
    """
    Hello #{member.name},

    You are invited to vote in “#{poll.title}”.

    Cast your vote: #{url}

    This voting link is personal to you. Do not forward or share it.
    Once submitted, your vote is final.
    """
  end

  defp html_body(poll, member, url) do
    name = escape(member.name)
    title = escape(poll.title)
    safe_url = escape(url)

    """
    <p>Hello #{name},</p>
    <p>You are invited to vote in <strong>#{title}</strong>.</p>
    <p><a href="#{safe_url}">Cast your vote</a></p>
    <p>This voting link is personal to you. Do not forward or share it.</p>
    <p>Once submitted, your vote is final.</p>
    """
  end

  defp escape(value), do: value |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()
end
