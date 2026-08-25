defmodule PollyWeb.AuditLiveTest do
  use PollyWeb.ConnCase

  alias Polly.Audit.Event
  alias Polly.Polls.Poll

  test "protects the audit routes", %{conn: conn} do
    assert {:error, {:redirect, %{to: "/sign-in"}}} = live(conn, ~p"/admin/audit")

    assert {:error, {:redirect, %{to: "/sign-in"}}} =
             live(conn, ~p"/admin/audit/#{Ash.UUID.generate()}")
  end

  test "lists events and renders safe event details", %{conn: conn} do
    {conn, actor} = register_and_log_in_administrator(conn)
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
end
