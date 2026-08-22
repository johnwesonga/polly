defmodule PollyWeb.PhaseTwoLiveTest do
  use PollyWeb.ConnCase

  alias Polly.Members.Member
  alias Polly.Polls.{AccessGrant, Poll}

  test "protects member and electorate management routes", %{conn: conn} do
    poll_id = Ash.UUID.generate()
    assert {:error, {:redirect, %{to: "/sign-in"}}} = live(conn, ~p"/admin/members")

    assert {:error, {:redirect, %{to: "/sign-in"}}} =
             live(conn, ~p"/admin/polls/#{poll_id}/electorate")
  end

  test "creates and edits roster members", %{conn: conn} do
    {conn, actor} = register_and_log_in_administrator(conn)
    {:ok, view, _html} = live(conn, ~p"/admin/members")

    view
    |> form("#new-member-form", member: %{name: "Jamie Rivera", email: "jamie@example.com"})
    |> render_submit()

    member = Ash.read_one!(Member, actor: actor)
    assert has_element?(view, "#members-#{member.id}")

    view |> element("#edit-member-#{member.id}") |> render_click()

    view
    |> form("#edit-member-form", member: %{name: "Jamie R.", active: false})
    |> render_submit()

    updated = Ash.get!(Member, member.id, actor: actor)
    assert updated.name == "Jamie R."
    refute updated.active
  end

  test "selects an electorate and manages its access link", %{conn: conn} do
    {conn, actor} = register_and_log_in_administrator(conn)
    poll = create_poll!(actor)

    member =
      Ash.create!(Member, %{name: "Jamie Rivera", email: "jamie@example.com"}, actor: actor)

    {:ok, empty_access, _html} = live(conn, ~p"/admin/polls/#{poll.id}/access")
    assert has_element?(empty_access, "#configure-electorate-link")

    {:ok, electorate, _html} = live(conn, ~p"/admin/polls/#{poll.id}/electorate")
    assert has_element?(electorate, "#ballot-preview")

    electorate |> element("#toggle-eligibility-#{member.id}") |> render_click()
    assert has_element?(electorate, "#eligible-count", "1 selected")
    assert has_element?(electorate, "#toggle-eligibility-#{member.id}", "Selected")

    {:ok, access, _html} = live(conn, ~p"/admin/polls/#{poll.id}/access")
    assert has_element?(access, "#access-link-#{member.id}")
    assert has_element?(access, "#access-link-#{member.id}[data-url^='http://localhost']")
    assert has_element?(access, "#access-members .pill.open", "Active")

    grant = Ash.read_one!(AccessGrant, actor: actor)
    access |> element("#reissue-access-link-#{member.id}") |> render_click()

    updated_grants = Ash.read!(AccessGrant, actor: actor)
    assert length(updated_grants) == 2
    assert Enum.any?(updated_grants, & &1.revoked_at)
    refute Enum.find(updated_grants, &is_nil(&1.revoked_at)).token == grant.token
  end

  defp create_poll!(actor) do
    Ash.create!(Poll, %{title: "Team Theme", slug: "team-theme"}, actor: actor)
  end
end
