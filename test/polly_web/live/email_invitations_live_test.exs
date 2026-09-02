defmodule PollyWeb.EmailInvitationsLiveTest do
  use PollyWeb.ConnCase
  use Oban.Testing, repo: Polly.Repo

  require Ash.Query

  alias Polly.Members.Member
  alias Polly.Polls.{Ballot, InvitationDelivery, Invitations, Option, Poll}

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

  test "previews, confirms, and queues reminders without replacing invitation status", %{
    conn: conn
  } do
    {conn, actor} = register_and_log_in_administrator(conn)
    {poll, [member]} = open_poll_with_members!(actor, 1)
    accept_initial_invitations!(poll, actor)

    {:ok, view, _html} = live(conn, ~p"/admin/polls/#{poll.id}/access")

    assert has_element?(view, "#reminder-emails")
    assert has_element?(view, "#reminder-readiness", "1 ready for reminder · 0 skipped")
    assert has_element?(view, "#invitation-status-#{member.id}", "Sent")

    view |> element("#prepare-reminder-emails") |> render_click()

    assert has_element?(view, "#reminder-confirmation", "Will be queued")
    assert has_element?(view, "#reminder-confirmation", "24-hour cooldown")
    assert has_element?(view, "#cancel-reminder-emails")

    view |> element("#cancel-reminder-emails") |> render_click()
    refute has_element?(view, "#reminder-confirmation")

    assert [] =
             InvitationDelivery
             |> Ash.Query.filter(kind == :reminder)
             |> Ash.read!(actor: actor)

    view |> element("#prepare-reminder-emails") |> render_click()
    view |> element("#confirm-reminder-emails") |> render_click()

    assert has_element?(view, "#reminder-status-#{member.id}", "Reminder queued")
    assert has_element?(view, "#invitation-status-#{member.id}", "Sent")

    reminder =
      InvitationDelivery
      |> Ash.Query.filter(kind == :reminder)
      |> Ash.read_one!(actor: actor)

    assert_enqueued(worker: Polly.Polls.InvitationWorker, args: %{"delivery_id" => reminder.id})

    Ash.update!(
      reminder,
      %{attempt_count: 1, last_error_code: "provider_error"},
      action: :fail,
      authorize?: false
    )

    send(view.pid, :refresh_invitation_status)

    assert has_element?(view, "#reminder-status-#{member.id}", "Reminder failed")
    assert has_element?(view, "#reminder-status-#{member.id}", "provider rejected delivery")
  end

  test "shows safe reminder skip reasons for members who already voted", %{conn: conn} do
    {conn, actor} = register_and_log_in_administrator(conn)
    {poll, [member]} = open_poll_with_members!(actor, 1)
    accept_initial_invitations!(poll, actor)

    Ash.create!(
      Ballot,
      %{poll_id: poll.id, member_id: member.id},
      action: :submit,
      authorize?: false
    )

    {:ok, view, _html} = live(conn, ~p"/admin/polls/#{poll.id}/access")

    assert has_element?(view, "#reminder-readiness", "0 ready for reminder · 1 skipped")
    assert has_element?(view, "#reminder-skip-breakdown", "1 Already voted")
    assert has_element?(view, "#prepare-reminder-emails[disabled]")
  end

  test "keeps electorate-wide reminder counts across access pagination", %{conn: conn} do
    {conn, actor} = register_and_log_in_administrator(conn)
    {poll, _members} = open_poll_with_members!(actor, 16)
    accept_initial_invitations!(poll, actor)

    {:ok, view, _html} = live(conn, ~p"/admin/polls/#{poll.id}/access?page=2")

    assert has_element?(view, "#reminder-readiness", "16 ready for reminder · 0 skipped")
    assert has_element?(view, "#previous-access-members-page")
    assert has_element?(view, "#prepare-reminder-emails:not([disabled])")
  end

  defp open_poll_with_members!(actor, count) do
    poll = Ash.create!(Poll, %{title: "Reminder Poll"}, actor: actor)

    members =
      Enum.map(1..count, fn number ->
        member =
          Ash.create!(
            Member,
            %{name: "Member #{number}", email: "member-#{number}@example.com"},
            actor: actor
          )

        Polly.Polls.Electorate.include_member(poll, member, actor)
        member
      end)

    Ash.create!(Option, %{poll_id: poll.id, label: "Cedar", position: 1}, actor: actor)
    Ash.create!(Option, %{poll_id: poll.id, label: "Quartz", position: 2}, actor: actor)
    poll = Ash.update!(poll, %{}, action: :open, actor: actor)
    {poll, members}
  end

  defp accept_initial_invitations!(poll, actor) do
    assert {:ok, deliveries} = Invitations.enqueue_bulk(poll, actor)

    Enum.each(deliveries, fn delivery ->
      Ash.update!(delivery, %{attempt_count: 1}, action: :accept, authorize?: false)
    end)
  end
end
