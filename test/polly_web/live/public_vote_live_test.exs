defmodule PollyWeb.PublicVoteLiveTest do
  use PollyWeb.ConnCase

  alias Polly.Members.Member
  alias Polly.Polls.{Ballots, Electorate, Option, Poll}

  setup %{conn: conn} do
    {_conn, actor} = register_and_log_in_administrator(conn)
    %{actor: actor}
  end

  test "an eligible member selects, reviews, and submits a final ballot", %{
    conn: conn,
    actor: actor
  } do
    fixture = open_poll!(actor, "Team theme")

    {:ok, view, _html} = live(conn, vote_path(fixture))

    assert has_element?(view, "#open-ballot")
    assert has_element?(view, "#ballot-form")
    assert has_element?(view, "#option-card-#{fixture.option.id}")
    assert has_element?(view, "#review-ballot-button[disabled]")

    view
    |> form("#ballot-form", ballot: %{option_id: fixture.option.id})
    |> render_change()

    refute has_element?(view, "#review-ballot-button[disabled]")

    view
    |> form("#ballot-form", ballot: %{option_id: fixture.option.id})
    |> render_submit()

    assert has_element?(view, "#ballot-review")
    assert has_element?(view, "#reviewed-option")

    view
    |> form("#confirm-ballot-form", ballot: %{option_id: fixture.option.id})
    |> render_submit()

    assert has_element?(view, "#ballot-submitted")
    refute has_element?(view, "#ballot-form")
  end

  test "a previously submitted ballot shows a distinct final state", %{conn: conn, actor: actor} do
    fixture = open_poll!(actor, "Final vote")

    assert {:ok, _ballot} =
             Ballots.submit(fixture.poll.id, fixture.grant.token, fixture.option.id)

    {:ok, view, _html} = live(conn, vote_path(fixture))

    assert has_element?(view, "#ballot-already-submitted")
    refute has_element?(view, "#confirm-ballot-button")
  end

  test "invalid and revoked links do not expose ballot details", %{conn: conn, actor: actor} do
    fixture = open_poll!(actor, "Private vote")

    {:ok, invalid_view, _html} =
      live(conn, ~p"/polls/#{fixture.poll.id}/vote/not-a-valid-token")

    assert has_element?(invalid_view, "#invalid-voting-link")
    refute has_element?(invalid_view, "#open-ballot")

    Ash.update!(fixture.grant, %{}, action: :revoke, actor: actor)
    {:ok, revoked_view, _html} = live(conn, vote_path(fixture))

    assert has_element?(revoked_view, "#invalid-voting-link")
    refute has_element?(revoked_view, "#open-ballot")
  end

  test "a draft poll explains that voting has not opened", %{conn: conn, actor: actor} do
    fixture = draft_poll!(actor, "Coming soon")

    {:ok, view, _html} = live(conn, vote_path(fixture))

    assert has_element?(view, "#poll-not-open")
    refute has_element?(view, "#ballot-form")
  end

  test "a closed poll waits for published results", %{conn: conn, actor: actor} do
    fixture = open_poll!(actor, "Closed vote")
    Ash.update!(fixture.poll, %{}, action: :close, actor: actor)

    {:ok, view, _html} = live(conn, vote_path(fixture))

    assert has_element?(view, "#poll-closed")
    refute has_element?(view, "#ballot-form")
  end

  test "published results are visible through a still-valid member link", %{
    conn: conn,
    actor: actor
  } do
    fixture = open_poll!(actor, "Published vote")

    assert {:ok, _ballot} =
             Ballots.submit(fixture.poll.id, fixture.grant.token, fixture.option.id)

    fixture.poll
    |> Ash.update!(%{}, action: :close, actor: actor)
    |> Ash.update!(%{}, action: :publish_results, actor: actor)

    {:ok, view, _html} = live(conn, vote_path(fixture))

    assert has_element?(view, "#published-results")
    assert has_element?(view, "#published-winner")
    assert has_element?(view, "#member-results")
    refute has_element?(view, "#poll-closed")
  end

  test "a revoked grant cannot view published results", %{conn: conn, actor: actor} do
    fixture = open_poll!(actor, "Revoked results")

    fixture.poll
    |> Ash.update!(%{}, action: :close, actor: actor)
    |> Ash.update!(%{}, action: :publish_results, actor: actor)

    Ash.update!(fixture.grant, %{}, action: :revoke, actor: actor)

    {:ok, view, _html} = live(conn, vote_path(fixture))

    assert has_element?(view, "#invalid-voting-link")
    refute has_element?(view, "#published-results")
  end

  defp open_poll!(actor, title) do
    fixture = draft_poll!(actor, title)
    %{fixture | poll: Ash.update!(fixture.poll, %{}, action: :open, actor: actor)}
  end

  defp draft_poll!(actor, title) do
    poll =
      Ash.create!(
        Poll,
        %{
          title: title,
          description: "Choose the direction for our next season.",
          slug: unique_slug(title)
        },
        actor: actor
      )

    option =
      Ash.create!(Option, %{poll_id: poll.id, label: "Under the Sea", position: 1}, actor: actor)

    Ash.create!(Option, %{poll_id: poll.id, label: "Retro Arcade", position: 2}, actor: actor)

    member = Ash.create!(Member, %{name: "Ava Kessler"}, actor: actor)
    {_eligibility, grant} = Electorate.include_member(poll, member, actor)

    %{poll: poll, option: option, member: member, grant: grant}
  end

  defp vote_path(fixture), do: ~p"/polls/#{fixture.poll.id}/vote/#{fixture.grant.token}"

  defp unique_slug(title) do
    "#{Polly.Polls.Slug.from_title(title)}-#{System.unique_integer([:positive])}"
  end
end
