defmodule PollyWeb.PollResultsLiveTest do
  use PollyWeb.ConnCase

  alias Polly.Members.Member
  alias Polly.Polls.{Ballots, Electorate, Option, Poll}

  test "protects the results management route", %{conn: conn} do
    assert {:error, {:redirect, %{to: "/sign-in"}}} =
             live(conn, ~p"/admin/polls/#{Ecto.UUID.generate()}/results")
  end

  test "opens, closes, and explicitly publishes a configured poll", %{conn: conn} do
    {conn, actor} = register_and_log_in_administrator(conn)
    fixture = draft_poll!(actor, "Lifecycle controls")

    {:ok, view, _html} = live(conn, ~p"/admin/polls/#{fixture.poll.id}/results")

    assert has_element?(view, "#open-poll-button")
    view |> element("#open-poll-button") |> render_click()
    assert has_element?(view, "#poll-results-status", "open")
    assert has_element?(view, "#close-poll-button")

    view |> element("#close-poll-button") |> render_click()
    assert has_element?(view, "#poll-results-status", "closed")
    assert has_element?(view, "#publish-results-button")

    view |> element("#publish-results-button") |> render_click()
    assert has_element?(view, "#results-published-status")
    refute has_element?(view, "#publish-results-button")
  end

  test "shows poll-scoped result totals and turnout", %{conn: conn} do
    {conn, actor} = register_and_log_in_administrator(conn)
    fixture = draft_poll!(actor, "Admin results")
    poll = Ash.update!(fixture.poll, %{}, action: :open, actor: actor)
    assert {:ok, _ballot} = Ballots.submit(poll.id, fixture.grant.token, [fixture.option.id])

    {:ok, view, _html} = live(conn, ~p"/admin/polls/#{poll.id}/results")

    assert has_element?(view, "#ballot-count", "1")
    assert has_element?(view, "#eligible-count", "1")
    assert has_element?(view, "#turnout-percentage", "100.0%")
    assert has_element?(view, "#result-#{fixture.option.id}")
    assert has_element?(view, "#winner-summary", "Leading: Under the Sea")

    assert has_element?(
             view,
             "#results-percentage-explanation",
             "share of submitted ballots"
           )

    refute has_element?(view, "#total-selections")
  end

  test "presents multiple-choice results as ballot support rates", %{conn: conn} do
    {conn, actor} = register_and_log_in_administrator(conn)
    fixture = draft_multiple_choice_poll!(actor, "Committee priorities")
    poll = Ash.update!(fixture.poll, %{}, action: :open, actor: actor)

    assert {:ok, _ballot} =
             Ballots.submit(
               poll.id,
               fixture.grant.token,
               [fixture.first_option.id, fixture.second_option.id]
             )

    {:ok, view, _html} = live(conn, ~p"/admin/polls/#{poll.id}/results")

    assert has_element?(view, "#ballot-count", "1")
    assert has_element?(view, "#total-selections", "2")
    assert has_element?(view, "#winner-summary", "Most selected (tie)")

    assert has_element?(
             view,
             "#results-percentage-explanation",
             "may total more than 100%"
           )

    assert has_element?(
             view,
             "#result-#{fixture.first_option.id} .result-num",
             "1 selection · selected by 100.0%"
           )

    assert has_element?(
             view,
             "#result-#{fixture.second_option.id} .result-num",
             "1 selection · selected by 100.0%"
           )
  end

  test "enables, shares, and withdraws public result access", %{conn: conn} do
    {conn, actor} = register_and_log_in_administrator(conn)
    fixture = draft_poll!(actor, "Public sharing controls")

    poll =
      fixture.poll
      |> Ash.update!(%{}, action: :open, actor: actor)
      |> Ash.update!(%{}, action: :close, actor: actor)
      |> Ash.update!(%{}, action: :publish_results, actor: actor)

    {:ok, view, _html} = live(conn, ~p"/admin/polls/#{poll.id}/results")

    assert has_element?(view, "#result-visibility-description", "require a member's private")
    assert has_element?(view, "#make-results-public-button")
    refute has_element?(view, "#public-results-link")

    view |> element("#make-results-public-button") |> render_click()

    assert has_element?(view, "#make-results-credentialed-button")
    assert has_element?(view, "#public-results-link")

    assert has_element?(
             view,
             "#view-public-results-link[href='/polls/#{poll.slug}/results']"
           )

    view |> element("#make-results-credentialed-button") |> render_click()

    assert has_element?(view, "#make-results-public-button")
    refute has_element?(view, "#public-results-link")
  end

  test "links to duplication configuration from the results page", %{conn: conn} do
    {conn, actor} = register_and_log_in_administrator(conn)
    fixture = draft_poll!(actor, "Reusable results poll")

    {:ok, view, _html} = live(conn, ~p"/admin/polls/#{fixture.poll.id}/results")
    assert has_element?(view, "#duplicate-poll-button")

    result = view |> element("#duplicate-poll-button") |> render_click()

    assert {:error, {:live_redirect, %{to: path}}} = result
    assert path == ~p"/admin/polls/#{fixture.poll.id}/duplicate"
  end

  test "confirms provisional and final CSV result exports", %{conn: conn} do
    {conn, actor} = register_and_log_in_administrator(conn)
    fixture = draft_poll!(actor, "Exportable results")

    {:ok, draft_view, _html} = live(conn, ~p"/admin/polls/#{fixture.poll.id}/results")
    assert has_element?(draft_view, "#export-results-button[disabled]")
    assert has_element?(draft_view, "#results-export-unavailable")

    poll = Ash.update!(fixture.poll, %{}, action: :open, actor: actor)
    {:ok, open_view, _html} = live(conn, ~p"/admin/polls/#{poll.id}/results")

    open_view |> element("#export-results-button") |> render_click()

    assert has_element?(open_view, "#results-export-confirmation", "provisional")

    assert has_element?(
             open_view,
             "#download-results-export[href='/admin/polls/#{poll.id}/results.csv']",
             "Download provisional results"
           )

    open_view |> element("#cancel-results-export") |> render_click()
    refute has_element?(open_view, "#results-export-confirmation")

    closed = Ash.update!(poll, %{}, action: :close, actor: actor)
    {:ok, closed_view, _html} = live(conn, ~p"/admin/polls/#{closed.id}/results")
    closed_view |> element("#export-results-button") |> render_click()

    assert has_element?(closed_view, "#results-export-confirmation", "final, unpublished")
    assert has_element?(closed_view, "#download-results-export", "Download final results")
    assert has_element?(closed_view, "#results-export-confirmation", "no member identities")
  end

  defp draft_poll!(actor, title) do
    poll =
      Ash.create!(
        Poll,
        %{title: title},
        actor: actor
      )

    option =
      Ash.create!(Option, %{poll_id: poll.id, label: "Under the Sea", position: 1}, actor: actor)

    Ash.create!(Option, %{poll_id: poll.id, label: "Retro Arcade", position: 2}, actor: actor)
    member = Ash.create!(Member, %{name: "Results voter"}, actor: actor)
    {_eligibility, grant} = Electorate.include_member(poll, member, actor)

    %{poll: poll, option: option, grant: grant}
  end

  defp draft_multiple_choice_poll!(actor, title) do
    poll =
      Ash.create!(
        Poll,
        %{
          title: title,
          selection_mode: :multiple,
          minimum_selections: 2,
          maximum_selections: 2
        },
        actor: actor
      )

    first_option =
      Ash.create!(Option, %{poll_id: poll.id, label: "First priority", position: 1}, actor: actor)

    second_option =
      Ash.create!(Option, %{poll_id: poll.id, label: "Second priority", position: 2},
        actor: actor
      )

    member = Ash.create!(Member, %{name: "Multiple-choice results voter"}, actor: actor)
    {_eligibility, grant} = Electorate.include_member(poll, member, actor)

    %{
      poll: poll,
      first_option: first_option,
      second_option: second_option,
      grant: grant
    }
  end
end
