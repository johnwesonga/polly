defmodule PollyWeb.EmailInvitationsLiveTest do
  use PollyWeb.ConnCase
  use Oban.Testing, repo: Polly.Repo

  alias Polly.Members.Member
  alias Polly.Polls.{InvitationDelivery, Option, Poll}

  test "queues ready invitations from the poll access page", %{conn: conn} do
    {conn, actor} = register_and_log_in_administrator(conn)
    poll = Ash.create!(Poll, %{title: "Board Election"}, actor: actor)

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
    assert has_element?(view, "#invitation-confirmation")
    assert has_element?(view, "#invitation-confirmation", "Will be queued")

    view |> element("#confirm-email-invitations") |> render_click()

    assert has_element?(view, "#invitation-status-#{member.id}", "Queued")
    assert [_delivery] = Ash.read!(InvitationDelivery, actor: actor)
    assert_enqueued(worker: Polly.Polls.InvitationWorker)
  end

  test "disables bulk delivery while the poll is a draft", %{conn: conn} do
    {conn, actor} = register_and_log_in_administrator(conn)
    poll = Ash.create!(Poll, %{title: "Draft Poll"}, actor: actor)

    {:ok, view, _html} = live(conn, ~p"/admin/polls/#{poll.id}/access")

    assert has_element?(view, "#send-email-invitations[disabled]")
    assert has_element?(view, "#invitation-readiness", "Open the poll before sending")
  end

  test "shows skipped reasons in readiness and bulk confirmation", %{conn: conn} do
    {conn, actor} = register_and_log_in_administrator(conn)
    poll = Ash.create!(Poll, %{title: "Mixed Electorate"}, actor: actor)

    ready = Ash.create!(Member, %{name: "Ready", email: "ready@example.com"}, actor: actor)
    missing = Ash.create!(Member, %{name: "Missing Email"}, actor: actor)

    Polly.Polls.Electorate.include_member(poll, ready, actor)
    Polly.Polls.Electorate.include_member(poll, missing, actor)
    Ash.create!(Option, %{poll_id: poll.id, label: "One", position: 1}, actor: actor)
    Ash.create!(Option, %{poll_id: poll.id, label: "Two", position: 2}, actor: actor)
    poll = Ash.update!(poll, %{}, action: :open, actor: actor)

    {:ok, view, _html} = live(conn, ~p"/admin/polls/#{poll.id}/access")

    assert has_element?(view, "#invitation-readiness", "1 ready · 1 skipped")
    assert has_element?(view, "#invitation-skip-breakdown", "1 Missing email")

    view |> element("#send-email-invitations") |> render_click()

    assert has_element?(view, "#invitation-confirmation", "Mixed Electorate")
    assert has_element?(view, "#invitation-confirmation", "Missing email")
    assert has_element?(view, "#invitation-confirmation", "private voting link")
  end

  test "refreshes accepted and failed delivery presentations", %{conn: conn} do
    {conn, actor} = register_and_log_in_administrator(conn)
    poll = Ash.create!(Poll, %{title: "Delivery Status"}, actor: actor)

    member =
      Ash.create!(Member, %{name: "Jamie Rivera", email: "jamie@example.com"}, actor: actor)

    Polly.Polls.Electorate.include_member(poll, member, actor)
    Ash.create!(Option, %{poll_id: poll.id, label: "One", position: 1}, actor: actor)
    Ash.create!(Option, %{poll_id: poll.id, label: "Two", position: 2}, actor: actor)
    poll = Ash.update!(poll, %{}, action: :open, actor: actor)

    {:ok, view, _html} = live(conn, ~p"/admin/polls/#{poll.id}/access")
    view |> element("#send-invitation-#{member.id}") |> render_click()
    [delivery] = Ash.read!(InvitationDelivery, actor: actor)

    delivery =
      Ash.update!(
        delivery,
        %{provider_message_id: "email-id", attempt_count: 1},
        action: :accept,
        authorize?: false
      )

    send(view.pid, :refresh_invitation_status)

    assert has_element?(view, "#invitation-status-#{member.id}", "Sent")

    assert has_element?(
             view,
             "#invitation-detail-#{member.id}",
             "Inbox delivery is not confirmed"
           )

    assert has_element?(view, "#resend-invitation-#{member.id}", "Resend email")

    Ash.update!(
      delivery,
      %{attempt_count: 2, last_error_code: "provider_error"},
      action: :fail,
      authorize?: false
    )

    send(view.pid, :refresh_invitation_status)

    assert has_element?(view, "#invitation-status-#{member.id}", "Failed")
    assert has_element?(view, "#invitation-detail-#{member.id}", "provider rejected delivery")
    assert has_element?(view, "#resend-invitation-#{member.id}", "Retry email")
  end
end
