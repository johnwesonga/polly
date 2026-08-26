defmodule PollyWeb.PollLiveTest do
  use PollyWeb.ConnCase

  require Ash.Query

  alias Polly.Members.Member
  alias Polly.Polls.{Eligibility, Option, Poll}

  test "protects poll management routes", %{conn: conn} do
    assert {:error, {:redirect, %{to: "/sign-in"}}} = live(conn, ~p"/admin/polls")
    assert {:error, {:redirect, %{to: "/sign-in"}}} = live(conn, ~p"/admin/polls/new")

    assert {:error, {:redirect, %{to: "/sign-in"}}} =
             live(conn, ~p"/admin/polls/#{Ecto.UUID.generate()}/duplicate")
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
    assert updated.slug == "updated-team-theme"
  end

  test "paginates the poll index with keyset cursors", %{conn: conn} do
    {conn, actor} = register_and_log_in_administrator(conn)

    polls =
      for number <- 1..26 do
        Ash.create!(
          Poll,
          %{title: "Paginated Poll #{number}", slug: "paginated-poll-#{number}"},
          actor: actor
        )
      end

    {:ok, view, _html} = live(conn, ~p"/admin/polls")

    assert has_element?(view, "#polls > article.poll-card:nth-of-type(25)")
    refute has_element?(view, "#polls > article.poll-card:nth-of-type(26)")
    assert has_element?(view, "#next-polls-page")
    refute has_element?(view, "#previous-polls-page")

    view |> element("#next-polls-page") |> render_click()

    assert has_element?(view, "#polls > article.poll-card:first-of-type")
    refute has_element?(view, "#polls > article.poll-card:nth-of-type(2)")

    assert has_element?(view, "#previous-polls-page")
    refute has_element?(view, "#next-polls-page")
    assert Enum.any?(polls, &has_element?(view, "#polls-#{&1.id}"))

    view |> element("#previous-polls-page") |> render_click()

    assert has_element?(view, "#polls > article.poll-card:nth-of-type(25)")
    refute has_element?(view, "#polls > article.poll-card:nth-of-type(26)")
    refute has_element?(view, "#previous-polls-page")
    assert has_element?(view, "#next-polls-page")
  end

  test "filters polls by lifecycle status before pagination", %{conn: conn} do
    {conn, actor} = register_and_log_in_administrator(conn)

    draft =
      Ash.create!(Poll, %{title: "Draft Listing", slug: "draft-listing"}, actor: actor)

    open = create_poll_with_status!(actor, "Open Listing", "open-listing", :open)
    closed = create_poll_with_status!(actor, "Closed Listing", "closed-listing", :closed)

    {:ok, view, _html} = live(conn, ~p"/admin/polls")

    assert has_element?(view, "#poll-filter-all.current")
    assert has_element?(view, "#polls-#{draft.id}")
    assert has_element?(view, "#polls-#{open.id}")
    assert has_element?(view, "#polls-#{closed.id}")

    view |> element("#poll-filter-draft") |> render_click()

    assert has_element?(view, "#poll-filter-draft.current")
    assert has_element?(view, "#polls-#{draft.id}")
    refute has_element?(view, "#polls-#{open.id}")
    refute has_element?(view, "#polls-#{closed.id}")

    view |> element("#poll-filter-open") |> render_click()

    assert has_element?(view, "#poll-filter-open.current")
    assert has_element?(view, "#polls-#{open.id}")
    refute has_element?(view, "#polls-#{draft.id}")
    refute has_element?(view, "#polls-#{closed.id}")
  end

  test "regenerates a unique slug when a draft title changes", %{conn: conn} do
    {conn, actor} = register_and_log_in_administrator(conn)
    poll = create_poll!(actor)

    Ash.create!(
      Poll,
      %{title: "Existing Title", slug: "existing-title"},
      actor: actor
    )

    {:ok, edit, _html} = live(conn, ~p"/admin/polls/#{poll.id}/edit")

    edit
    |> form("#poll-form", poll: %{title: "Existing Title", description: "Changed"})
    |> render_submit()

    updated = Ash.get!(Poll, poll.id, actor: actor)
    assert updated.title == "Existing Title"
    assert updated.slug == "existing-title-2"
  end

  test "configures a duplicate from the poll list and opens the new draft editor", %{conn: conn} do
    {conn, actor} = register_and_log_in_administrator(conn)
    poll = create_poll!(actor)
    create_option!(poll, actor, "Under the Sea", 1)

    active_member = Ash.create!(Member, %{name: "Active copy member"}, actor: actor)
    Ash.create!(Eligibility, %{poll_id: poll.id, member_id: active_member.id}, actor: actor)

    inactive_member = Ash.create!(Member, %{name: "Inactive copy member"}, actor: actor)
    Ash.create!(Eligibility, %{poll_id: poll.id, member_id: inactive_member.id}, actor: actor)
    Ash.update!(inactive_member, %{active: false}, actor: actor)

    {:ok, index, _html} = live(conn, ~p"/admin/polls")
    assert has_element?(index, "#poll-duplicate-#{poll.id}")

    result = index |> element("#poll-duplicate-#{poll.id}") |> render_click()

    assert {:error, {:live_redirect, %{to: path}}} = result
    assert path == ~p"/admin/polls/#{poll.id}/duplicate"

    {:ok, duplicate_view, _html} = live(conn, path)
    assert has_element?(duplicate_view, "#duplicate-poll-form")
    assert has_element?(duplicate_view, "#duplicate_copy_options[checked]")
    refute has_element?(duplicate_view, "#duplicate_copy_electorate[checked]")
    assert has_element?(duplicate_view, "#preview-option-count", "1")
    assert has_element?(duplicate_view, "#preview-member-count", "0")

    duplicate_view
    |> form("#duplicate-poll-form",
      duplicate: %{copy_options: "true", copy_electorate: "true"}
    )
    |> render_change()

    assert has_element?(duplicate_view, "#preview-member-count", "1")
    assert has_element?(duplicate_view, "#skipped-members-warning")

    submit_result =
      duplicate_view
      |> form("#duplicate-poll-form",
        duplicate: %{copy_options: "true", copy_electorate: "false"}
      )
      |> render_submit()

    assert {:error, {:live_redirect, %{to: edit_path}}} = submit_result
    assert edit_path =~ ~r{/admin/polls/.+/edit$}

    duplicate =
      Poll
      |> Ash.Query.filter(slug == "copy-of-team-theme")
      |> Ash.read_one!(actor: actor)

    assert duplicate.title == "Copy of Team Theme"
    assert Enum.map(list_options(duplicate, actor), & &1.label) == ["Under the Sea"]
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

  defp create_poll_with_status!(actor, title, slug, status) do
    poll = Ash.create!(Poll, %{title: title, slug: slug}, actor: actor)
    create_option!(poll, actor, "One", 1)
    create_option!(poll, actor, "Two", 2)

    member = Ash.create!(Member, %{name: "#{title} Member"}, actor: actor)
    Ash.create!(Eligibility, %{poll_id: poll.id, member_id: member.id}, actor: actor)

    poll = Ash.update!(poll, %{}, action: :open, actor: actor)

    if status == :closed do
      Ash.update!(poll, %{}, action: :close, actor: actor)
    else
      poll
    end
  end

  defp list_options(poll, actor) do
    Option
    |> Ash.Query.filter(poll_id == ^poll.id)
    |> Ash.Query.sort(position: :asc)
    |> Ash.read!(actor: actor)
  end
end
