defmodule PollyWeb.PollLifecycleLiveTest do
  use PollyWeb.ConnCase

  alias Polly.Members.Member
  alias Polly.Polls.{Electorate, LifecycleScheduling, Option, Poll}

  test "protects the lifecycle route", %{conn: conn} do
    assert {:error, {:redirect, %{to: "/sign-in"}}} =
             live(conn, ~p"/admin/polls/#{Ecto.UUID.generate()}/lifecycle")
  end

  test "rejects an administrator without either lifecycle permission", %{conn: conn} do
    {conn, _actor} = register_and_log_in_administrator(conn, %{role: :operator})

    assert {:error, {:redirect, %{to: "/admin"}}} =
             live(conn, ~p"/admin/polls/#{Ecto.UUID.generate()}/lifecycle")
  end

  test "shows draft readiness and confirms manual opening and closing", %{conn: conn} do
    {conn, actor} = register_and_log_in_administrator(conn)
    poll = configured_poll!(actor, "Lifecycle page", :anonymous)

    {:ok, view, _html} = live(conn, ~p"/admin/polls/#{poll.id}/lifecycle")

    assert has_element?(view, "#poll-readiness .pill", "Ready")
    assert has_element?(view, "#schedule-open-form")
    assert has_element?(view, "#schedule-close-form")

    view |> element("#open-poll-now-button") |> render_click()
    assert has_element?(view, "#lifecycle-confirmation", "Choices will not be associated")
    assert Ash.get!(Poll, poll.id, actor: actor).status == :draft

    view |> element("#confirm-lifecycle-action") |> render_click()
    assert has_element?(view, "#poll-lifecycle-status", "open")
    assert Ash.get!(Poll, poll.id, actor: actor).status == :open

    view |> element("#close-poll-now-button") |> render_click()
    assert has_element?(view, "#lifecycle-confirmation", "immediately stops")
    view |> element("#confirm-lifecycle-action") |> render_click()

    assert has_element?(view, "#poll-lifecycle-status", "closed")
    assert has_element?(view, "#closed-lifecycle-message")
    refute has_element?(view, "#schedule-open-form")
    refute has_element?(view, "#schedule-close-form")
  end

  test "schedules, replaces, and cancels a pending transition", %{conn: conn} do
    {conn, actor} = register_and_log_in_administrator(conn)
    poll = configured_poll!(actor, "Scheduled lifecycle")
    initial = future_datetime_local(2)
    replacement = future_datetime_local(3)

    {:ok, view, _html} = live(conn, ~p"/admin/polls/#{poll.id}/lifecycle")

    view
    |> form("#schedule-open-form", schedule_open: %{scheduled_at: initial})
    |> render_submit(%{"kind" => "open"})

    assert has_element?(view, "#lifecycle-confirmation", "scheduled for")
    view |> element("#confirm-lifecycle-action") |> render_click()

    {:ok, [transition]} = LifecycleScheduling.list_for_poll(poll, actor)
    assert has_element?(view, "#pending-transition-#{transition.id}")
    refute has_element?(view, "#schedule-open-form")

    view
    |> form("#replace-transition-form-#{transition.id}",
      replacement: %{scheduled_at: replacement}
    )
    |> render_submit()

    assert has_element?(view, "#lifecycle-confirmation", "cancelled and replaced")
    view |> element("#confirm-lifecycle-action") |> render_click()

    {:ok, transitions} = LifecycleScheduling.list_for_poll(poll, actor)
    replacement_transition = Enum.find(transitions, &(&1.state == :pending))
    assert replacement_transition.id != transition.id
    assert has_element?(view, "#pending-transition-#{replacement_transition.id}")

    view |> element("#cancel-transition-#{replacement_transition.id}") |> render_click()
    assert has_element?(view, "#lifecycle-confirmation", "will be cancelled")
    view |> element("#confirm-lifecycle-action") |> render_click()

    assert has_element?(view, "#pending-transitions-empty")
    assert has_element?(view, "#transition-history-#{replacement_transition.id}", "cancelled")
  end

  defp configured_poll!(actor, title, privacy_mode \\ :identified) do
    poll =
      Ash.create!(
        Poll,
        %{title: title, privacy_mode: privacy_mode},
        actor: actor
      )

    Ash.create!(Option, %{poll_id: poll.id, label: "First", position: 1}, actor: actor)
    Ash.create!(Option, %{poll_id: poll.id, label: "Second", position: 2}, actor: actor)
    member = Ash.create!(Member, %{name: "Lifecycle voter"}, actor: actor)
    Electorate.include_member(poll, member, actor)
    poll
  end

  defp future_datetime_local(hours) do
    DateTime.utc_now()
    |> DateTime.add(hours, :hour)
    |> Calendar.strftime("%Y-%m-%dT%H:%M")
  end
end
