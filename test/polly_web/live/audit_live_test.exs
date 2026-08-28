defmodule PollyWeb.AuditLiveTest do
  use PollyWeb.ConnCase

  alias Polly.Audit
  alias Polly.Audit.Event
  alias Polly.Accounts.User
  alias Polly.Polls.Poll

  test "protects the audit routes", %{conn: conn} do
    assert {:error, {:redirect, %{to: "/sign-in"}}} = live(conn, ~p"/admin/audit")

    assert {:error, {:redirect, %{to: "/sign-in"}}} =
             live(conn, ~p"/admin/audit/#{Ash.UUID.generate()}")
  end

  test "lists events and renders safe event details", %{conn: conn} do
    {conn, actor} = register_and_log_in_administrator(conn, %{role: :owner})
    poll = Ash.create!(Poll, %{title: "Visible audit", slug: "visible-audit"}, actor: actor)
    event = Ash.read_one!(Event, actor: actor)

    {:ok, view, _html} = live(conn, ~p"/admin/audit")
    assert has_element?(view, "#admin-nav-audit.current")
    assert has_element?(view, "#audit-events article", "created poll")
    assert has_element?(view, "#view-audit-event-#{event.id}")

    {:ok, detail, _html} = live(conn, ~p"/admin/audit/#{event.id}")
    assert has_element?(detail, "#audit-event-detail", poll.title)
    refute has_element?(detail, "#audit-event-detail button")
  end

  test "filters with URL parameters and paginates using keysets", %{conn: conn} do
    {conn, actor} = register_and_log_in_administrator(conn, %{role: :owner})

    for index <- 1..27 do
      Audit.append!(%{
        action: "member.created",
        actor: actor,
        target: %{type: "member", id: Ash.UUID.generate(), label: "Member #{index}"}
      })
    end

    for index <- 1..3 do
      Audit.append!(%{
        action: "poll.created",
        actor: actor,
        target: %{type: "poll", id: Ash.UUID.generate(), label: "Poll #{index}"}
      })
    end

    {:ok, view, _html} = live(conn, ~p"/admin/audit")
    assert has_element?(view, "#audit-event-count", "30 matching events")
    assert has_element?(view, "#load-more-audit-events")

    view |> element("#load-more-audit-events") |> render_click()
    refute has_element?(view, "#load-more-audit-events")

    view
    |> form("#audit-filters", filters: %{category: "poll"})
    |> render_change()

    assert_patch(view, ~p"/admin/audit?category=poll")
    assert has_element?(view, "#audit-event-count", "3 matching events")
    refute has_element?(view, "#audit-events article", "Member 1")
    assert has_element?(view, "#audit-events article", "Poll 1")
  end

  test "opens and closes details with patches while preserving filters", %{conn: conn} do
    {conn, actor} = register_and_log_in_administrator(conn, %{role: :owner})

    event =
      Audit.append!(%{
        action: "poll.created",
        actor: actor,
        target: %{type: "poll", id: Ash.UUID.generate(), label: "Patched details"}
      })

    {:ok, view, _html} = live(conn, ~p"/admin/audit?category=poll")

    view |> element("#view-audit-event-#{event.id}") |> render_click()
    assert_patch(view, ~p"/admin/audit/#{event.id}?category=poll")
    assert has_element?(view, "#audit-event-detail", "Patched details")

    assert has_element?(
             view,
             "#audit-filters select[name='filters[category]'] option[selected][value='poll']"
           )

    view |> element("#audit-event-detail a", "Close") |> render_click()
    assert_patch(view, ~p"/admin/audit?category=poll")
  end

  test "filters by actor, target, poll, and date", %{conn: conn} do
    {conn, actor} = register_and_log_in_administrator(conn, %{role: :owner})

    other_actor =
      Ash.create!(
        User,
        %{
          email: "other-auditor@example.com",
          password: "secure-password",
          password_confirmation: "secure-password"
        },
        action: :register_with_password,
        authorize?: false
      )

    poll_id = Ash.UUID.generate()

    Audit.append!(%{
      action: "poll.created",
      actor: actor,
      target: %{type: "poll", id: poll_id, label: "Filtered poll"},
      poll_id: poll_id
    })

    Audit.append!(%{
      action: "member.created",
      actor: other_actor,
      target: %{type: "member", id: Ash.UUID.generate(), label: "Filtered member"}
    })

    today = Date.utc_today() |> Date.to_iso8601()

    {:ok, actor_view, _html} = live(conn, ~p"/admin/audit?actor_id=#{actor.id}")
    assert has_element?(actor_view, "#audit-event-count", "1 matching events")
    assert has_element?(actor_view, "#audit-events article", "Filtered poll")

    {:ok, target_view, _html} = live(conn, ~p"/admin/audit?target_type=member")
    assert has_element?(target_view, "#audit-event-count", "1 matching events")

    {:ok, poll_view, _html} = live(conn, ~p"/admin/audit?poll_id=#{poll_id}")
    assert has_element?(poll_view, "#audit-event-count", "1 matching events")

    {:ok, date_view, _html} =
      live(conn, ~p"/admin/audit?date_from=#{today}&date_to=#{today}")

    assert has_element?(date_view, "#audit-event-count", "2 matching events")
  end
end
