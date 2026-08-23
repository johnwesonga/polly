defmodule PollyWeb.PollLiveTest do
  use PollyWeb.ConnCase

  require Ash.Query

  alias Polly.Members.Member
  alias Polly.Polls.{Eligibility, Option, Poll}

  test "protects poll management routes", %{conn: conn} do
    assert {:error, {:redirect, %{to: "/sign-in"}}} = live(conn, ~p"/admin/polls")
    assert {:error, {:redirect, %{to: "/sign-in"}}} = live(conn, ~p"/admin/polls/new")
  end

  test "creates a draft and navigates to option management", %{conn: conn} do
    {conn, actor} = register_and_log_in_administrator(conn)
    {:ok, view, _html} = live(conn, ~p"/admin/polls/new")

    assert has_element?(view, "#poll-form")

    result =
      view
      |> form("#poll-form", poll: %{title: "2027 Team Theme", description: "Choose a theme"})
      |> render_submit()

    assert {:error, {:live_redirect, %{to: path}}} = result
    assert path =~ "/admin/polls/"
    assert path =~ "/options"

    poll = Ash.read_one!(Poll, actor: actor)
    assert poll.title == "2027 Team Theme"
    assert poll.slug == "2027-team-theme"
  end

  test "lists and edits draft polls", %{conn: conn} do
    {conn, actor} = register_and_log_in_administrator(conn)
    poll = create_poll!(actor)

    {:ok, index, _html} = live(conn, ~p"/admin/polls")
    assert has_element?(index, "#polls-#{poll.id}")
    assert has_element?(index, "#poll-edit-#{poll.id}")

    {:ok, edit, _html} = live(conn, ~p"/admin/polls/#{poll.id}/edit")

    edit
    |> form("#poll-form", poll: %{title: "Updated Team Theme", description: "Updated"})
    |> render_submit()

    updated = Ash.get!(Poll, poll.id, actor: actor)
    assert updated.title == "Updated Team Theme"
    assert updated.slug == poll.slug
  end

  test "duplicates poll details from the poll list and opens the new draft editor", %{conn: conn} do
    {conn, actor} = register_and_log_in_administrator(conn)
    poll = create_poll!(actor)
    create_option!(poll, actor, "Under the Sea", 1)

    {:ok, index, _html} = live(conn, ~p"/admin/polls")
    assert has_element?(index, "#poll-duplicate-#{poll.id}")

    result = index |> element("#poll-duplicate-#{poll.id}") |> render_click()

    assert {:error, {:live_redirect, %{to: path}}} = result
    assert path =~ ~r{/admin/polls/.+/edit$}

    duplicate =
      Poll
      |> Ash.Query.filter(slug == "team-theme-copy")
      |> Ash.read_one!(actor: actor)

    assert duplicate.title == "Copy of Team Theme"
    assert list_options(duplicate, actor) == []
  end

  test "adds, renames, moves, and deletes options", %{conn: conn} do
    {conn, actor} = register_and_log_in_administrator(conn)
    poll = create_poll!(actor)
    first = create_option!(poll, actor, "Under the Sea", 1)
    second = create_option!(poll, actor, "Retro Arcade", 2)

    {:ok, view, _html} = live(conn, ~p"/admin/polls/#{poll.id}/options")
    assert has_element?(view, "#options-#{first.id}")

    view
    |> form("#new-option-form", option: %{label: "Wild West"})
    |> render_submit()

    assert has_element?(view, "#option-count", "3 options")

    view |> element("#edit-option-#{first.id}") |> render_click()
    assert has_element?(view, "#edit-option-form")

    view
    |> form("#edit-option-form", option: %{label: "Ocean Adventure"})
    |> render_submit()

    assert has_element?(view, "#poll-options", "Ocean Adventure")

    view |> element("#move-option-up-#{second.id}") |> render_click()
    reordered = list_options(poll, actor)

    assert reordered |> Enum.map(& &1.label) |> Enum.take(2) == [
             "Retro Arcade",
             "Ocean Adventure"
           ]

    third = Enum.find(reordered, &(&1.label == "Wild West"))
    view |> element("#delete-option-#{third.id}") |> render_click()
    refute has_element?(view, "#options-#{third.id}")
    assert length(list_options(poll, actor)) == 2
  end

  test "shows frozen options for an open poll", %{conn: conn} do
    {conn, actor} = register_and_log_in_administrator(conn)
    poll = create_poll!(actor)
    create_option!(poll, actor, "Under the Sea", 1)
    create_option!(poll, actor, "Retro Arcade", 2)
    member = Ash.create!(Member, %{name: "Eligible Member"}, actor: actor)
    Ash.create!(Eligibility, %{poll_id: poll.id, member_id: member.id}, actor: actor)
    poll = Ash.update!(poll, %{}, action: :open, actor: actor)

    {:ok, view, _html} = live(conn, ~p"/admin/polls/#{poll.id}/options")

    assert has_element?(view, "#options-frozen-notice")
    refute has_element?(view, "#new-option-form")
  end

  defp create_poll!(actor) do
    Ash.create!(
      Poll,
      %{title: "Team Theme", description: "Choose", slug: "team-theme"},
      actor: actor
    )
  end

  defp create_option!(poll, actor, label, position) do
    Ash.create!(Option, %{poll_id: poll.id, label: label, position: position}, actor: actor)
  end

  defp list_options(poll, actor) do
    Option
    |> Ash.Query.filter(poll_id == ^poll.id)
    |> Ash.Query.sort(position: :asc)
    |> Ash.read!(actor: actor)
  end
end
