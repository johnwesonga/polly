defmodule PollyWeb.PublicPollResultsLiveTest do
  use PollyWeb.ConnCase

  alias Polly.Members.Member
  alias Polly.Polls.{Ballots, Electorate, Option, Poll}

  test "renders published public aggregate results without credentials", %{conn: conn} do
    {_authenticated_conn, actor} = register_and_log_in_administrator(conn)
    fixture = published_public_poll!(actor)
    path = ~p"/polls/#{fixture.poll.slug}/results"

    response = get(conn, path)
    assert html_response(response, 200)
    assert get_resp_header(response, "cache-control") == ["private, no-store"]
    assert get_resp_header(response, "x-robots-tag") == ["noindex, nofollow"]

    {:ok, view, _html} = live(conn, path)

    assert has_element?(view, "#public-results-page")
    assert has_element?(view, "#public-results-summary", "Most selected (tie)")
    assert has_element?(view, "#public-total-selections", "2 total selections")
    assert has_element?(view, "#public-results-explanation", "may total more than 100%")
    assert has_element?(view, "#public-result-#{fixture.first.id}", "selected by 100.0%")
    assert has_element?(view, "#public-result-#{fixture.second.id}", "selected by 100.0%")
    refute has_element?(view, "#ballot-form")
    refute render(view) =~ voting_token(fixture.grant)
    refute render(view) =~ fixture.member.name
  end

  test "unavailable public result URLs return not found", %{conn: conn} do
    {_authenticated_conn, actor} = register_and_log_in_administrator(conn)
    poll = configured_poll!(actor, "Credentialed results").poll
    poll = Ash.update!(poll, %{}, action: :open, actor: actor)
    poll = Ash.update!(poll, %{}, action: :close, actor: actor)
    poll = Ash.update!(poll, %{}, action: :publish_results, actor: actor)

    assert_raise PollyWeb.NotFoundError, fn ->
      get(conn, ~p"/polls/#{poll.slug}/results")
    end

    assert_raise PollyWeb.NotFoundError, fn ->
      get(conn, "/polls/unknown-public-poll/results")
    end
  end

  defp published_public_poll!(actor) do
    fixture = configured_poll!(actor, "Public priorities")
    poll = Ash.update!(fixture.poll, %{}, action: :open, actor: actor)

    assert {:ok, _ballot} =
             Ballots.submit(poll.id, voting_token(fixture.grant), [
               fixture.first.id,
               fixture.second.id
             ])

    poll = Ash.update!(poll, %{}, action: :close, actor: actor)
    poll = Ash.update!(poll, %{}, action: :publish_results, actor: actor)
    poll = Ash.update!(poll, %{}, action: :make_results_public, actor: actor)

    %{fixture | poll: poll}
  end

  defp configured_poll!(actor, title) do
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

    first = Ash.create!(Option, %{poll_id: poll.id, label: "Alpha", position: 1}, actor: actor)
    second = Ash.create!(Option, %{poll_id: poll.id, label: "Beta", position: 2}, actor: actor)
    member = Ash.create!(Member, %{name: "Hidden voter"}, actor: actor)
    {_eligibility, grant} = Electorate.include_member(poll, member, actor)

    %{poll: poll, first: first, second: second, member: member, grant: grant}
  end
end
