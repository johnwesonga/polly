defmodule PollyWeb.EmailInvitationsLiveTest do
  use PollyWeb.ConnCase
  use Oban.Testing, repo: Polly.Repo

  alias Polly.Members.Member
  alias Polly.Polls.{InvitationDelivery, Option, Poll}

  test "queues ready invitations from the poll access page", %{conn: conn} do
    {conn, actor} = register_and_log_in_administrator(conn)
    poll = Ash.create!(Poll, %{title: "Board Election", slug: "board-election"}, actor: actor)

    member =
      Ash.create!(Member, %{name: "Jamie Rivera", email: "jamie@example.com"}, actor: actor)

    Polly.Polls.Electorate.include_member(poll, member, actor)
    Ash.create!(Option, %{poll_id: poll.id, label: "One", position: 1}, actor: actor)
    Ash.create!(Option, %{poll_id: poll.id, label: "Two", position: 2}, actor: actor)
    poll = Ash.update!(poll, %{}, action: :open, actor: actor)

    {:ok, view, _html} = live(conn, ~p"/admin/polls/#{poll.id}/access")

    assert has_element?(view, "#email-invitations")
    assert has_element?(view, "#invitation-readiness", "1 ready")
    assert has_element?(view, "#send-invitation-#{member.id}")

    view |> element("#send-email-invitations") |> render_click()

    assert has_element?(view, "#invitation-status-#{member.id}", "Queued")
    assert [_delivery] = Ash.read!(InvitationDelivery, actor: actor)
    assert_enqueued(worker: Polly.Polls.InvitationWorker)
  end

  test "disables bulk delivery while the poll is a draft", %{conn: conn} do
    {conn, actor} = register_and_log_in_administrator(conn)
    poll = Ash.create!(Poll, %{title: "Draft Poll", slug: "draft-poll"}, actor: actor)

    {:ok, view, _html} = live(conn, ~p"/admin/polls/#{poll.id}/access")

    assert has_element?(view, "#send-email-invitations[disabled]")
    assert has_element?(view, "#invitation-readiness", "Open the poll before sending")
  end
end
