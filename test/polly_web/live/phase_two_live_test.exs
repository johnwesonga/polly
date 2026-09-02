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

  test "paginates the member roster with stable next and previous navigation", %{conn: conn} do
    {conn, actor} = register_and_log_in_administrator(conn)

    members =
      Enum.map(1..26, fn number ->
        Ash.create!(
          Member,
          %{name: "Paged Member #{number |> Integer.to_string() |> String.pad_leading(2, "0")}"},
          actor: actor
        )
      end)

    first = List.first(members)
    fifteenth = Enum.at(members, 14)
    sixteenth = Enum.at(members, 15)
    last = List.last(members)
    {:ok, view, _html} = live(conn, ~p"/admin/members")

    assert has_element?(view, "#member-count", "26 members")

    assert has_element?(view, "#members-#{first.id}")
    assert has_element?(view, "#members-#{fifteenth.id}")
    refute has_element?(view, "#members-#{sixteenth.id}")
    refute has_element?(view, "#members-#{last.id}")
    assert has_element?(view, "#next-members-page")
    refute has_element?(view, "#previous-members-page")

    view |> element("#next-members-page") |> render_click()

    refute has_element?(view, "#members-#{first.id}")
    assert has_element?(view, "#members-#{sixteenth.id}")
    assert has_element?(view, "#members-#{last.id}")
    assert has_element?(view, "#previous-members-page")
    refute has_element?(view, "#next-members-page")

    view |> element("#previous-members-page") |> render_click()

    assert has_element?(view, "#members-#{first.id}")
    refute has_element?(view, "#members-#{last.id}")
  end

  test "selects an electorate and manages access without exposing its credential", %{conn: conn} do
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
    assert has_element?(access, "#protected-voting-credentials", "cannot be viewed or copied")
    assert has_element?(access, "#protected-access-#{member.id}", "credential hidden")
    refute has_element?(access, "#access-link-#{member.id}")
    refute has_element?(access, "#copy-access-link-#{member.id}")
    assert has_element?(access, "#access-members .pill.open", "Active")

    grant = Ash.read_one!(AccessGrant, actor: actor)
    html = render(access)
    refute html =~ voting_token(grant)
    refute html =~ "/polls/#{poll.id}/vote/"
    refute html =~ "data-copy-value"

    access |> element("#reissue-access-link-#{member.id}") |> render_click()

    updated_grants = Ash.read!(AccessGrant, actor: actor)
    assert length(updated_grants) == 2
    assert Enum.any?(updated_grants, & &1.revoked_at)

    assert updated_grants
           |> Enum.find(&is_nil(&1.revoked_at))
           |> voting_token() != voting_token(grant)
  end

  test "selects and unselects all active electorate members", %{conn: conn} do
    {conn, actor} = register_and_log_in_administrator(conn)
    poll = create_poll!(actor)

    first = Ash.create!(Member, %{name: "First member", email: "first@example.com"}, actor: actor)

    second =
      Ash.create!(Member, %{name: "Second member", email: "second@example.com"}, actor: actor)

    _inactive =
      Member
      |> Ash.create!(%{name: "Inactive member"}, actor: actor)
      |> Ash.update!(%{active: false}, actor: actor)

    {:ok, electorate, _html} = live(conn, ~p"/admin/polls/#{poll.id}/electorate")

    refute has_element?(electorate, "#unselect-all-members")
    electorate |> element("#select-all-members") |> render_click()

    assert has_element?(electorate, "#eligible-count", "2 selected")
    assert has_element?(electorate, "#toggle-eligibility-#{first.id}", "Selected")
    assert has_element?(electorate, "#toggle-eligibility-#{second.id}", "Selected")
    assert has_element?(electorate, "#unselect-all-members")

    electorate |> element("#unselect-all-members") |> render_click()

    assert has_element?(electorate, "#eligible-count", "0 selected")
    assert has_element?(electorate, "#toggle-eligibility-#{first.id}", "Select")
    assert has_element?(electorate, "#toggle-eligibility-#{second.id}", "Select")
    refute has_element?(electorate, "#unselect-all-members")

    grants = Ash.read!(AccessGrant, actor: actor)
    assert length(grants) == 2
    assert Enum.all?(grants, & &1.revoked_at)
  end

  test "paginates electorate members while select all applies to the full roster", %{conn: conn} do
    {conn, actor} = register_and_log_in_administrator(conn)
    poll = create_poll!(actor)

    members =
      Enum.map(1..16, fn number ->
        Ash.create!(
          Member,
          %{name: "Voter #{number |> Integer.to_string() |> String.pad_leading(2, "0")}"},
          actor: actor
        )
      end)

    fifteenth = Enum.at(members, 14)
    sixteenth = Enum.at(members, 15)
    {:ok, electorate, _html} = live(conn, ~p"/admin/polls/#{poll.id}/electorate")

    assert has_element?(electorate, "#toggle-eligibility-#{fifteenth.id}")
    refute has_element?(electorate, "#toggle-eligibility-#{sixteenth.id}")
    assert has_element?(electorate, "#next-electorate-members-page")

    electorate |> element("#select-all-members") |> render_click()
    assert has_element?(electorate, "#eligible-count", "16 selected")

    electorate |> element("#next-electorate-members-page") |> render_click()

    assert has_element?(electorate, "#toggle-eligibility-#{sixteenth.id}", "Selected")
    assert has_element?(electorate, "#previous-electorate-members-page")
    refute has_element?(electorate, "#next-electorate-members-page")

    electorate |> element("#unselect-all-members") |> render_click()
    assert has_element?(electorate, "#eligible-count", "0 selected")
    assert has_element?(electorate, "#toggle-eligibility-#{sixteenth.id}", "Select")
  end

  test "paginates voter access rows while retaining electorate-wide counts", %{conn: conn} do
    {conn, actor} = register_and_log_in_administrator(conn)
    poll = create_poll!(actor)

    members =
      Enum.map(1..16, fn number ->
        member =
          Ash.create!(
            Member,
            %{
              name: "Access Voter #{number |> Integer.to_string() |> String.pad_leading(2, "0")}",
              email: "access-voter-#{number}@example.com"
            },
            actor: actor
          )

        Polly.Polls.Electorate.include_member(poll, member, actor)
        member
      end)

    first = List.first(members)
    last = List.last(members)
    {:ok, access, _html} = live(conn, ~p"/admin/polls/#{poll.id}/access")

    assert has_element?(access, "#active-grant-count", "16 of 16 active")
    assert has_element?(access, "#invitation-readiness", "0 ready · 16 skipped")
    assert has_element?(access, "#protected-access-#{first.id}")
    refute has_element?(access, "#protected-access-#{last.id}")
    assert has_element?(access, "#next-access-members-page")
    refute has_element?(access, "#previous-access-members-page")

    access |> element("#next-access-members-page") |> render_click()

    refute has_element?(access, "#protected-access-#{first.id}")
    assert has_element?(access, "#protected-access-#{last.id}")
    assert has_element?(access, "#previous-access-members-page")
    refute has_element?(access, "#next-access-members-page")
  end

  defp create_poll!(actor) do
    Ash.create!(Poll, %{title: "Team Theme"}, actor: actor)
  end
end
