defmodule Polly.Polls.ResultsTest do
  use Polly.DataCase

  alias Polly.Accounts.User
  alias Polly.Members.Member
  alias Polly.Polls.{Ballots, Electorate, Events, Option, Poll, Results}

  setup do
    actor =
      Ash.create!(
        User,
        %{
          email: "results-admin-#{System.unique_integer([:positive])}@example.com",
          password: "secure-password",
          password_confirmation: "secure-password"
        },
        action: :register_with_password,
        authorize?: false
      )

    %{actor: actor}
  end

  test "calculates poll-scoped ties, percentages, turnout, and zero-vote options", %{actor: actor} do
    fixture = open_poll!(actor, "Results projection", 5)
    other = open_poll!(actor, "Other poll", 1)

    submit!(fixture, 0, fixture.first)
    submit!(fixture, 1, fixture.first)
    submit!(fixture, 2, fixture.second)
    submit!(fixture, 3, fixture.second)
    submit!(other, 0, other.first)

    result = Results.for_poll(fixture.poll)

    assert result.selection_mode == :single
    assert result.total_selections == 4
    assert result.ballot_count == 4
    assert result.eligible_count == 5
    assert result.turnout_percentage == 80.0
    assert result.winner_labels == ["Alpha", "Beta"]

    assert [first, second, third] = result.options
    assert %{votes: 2, percentage: 50.0, rank: 1, winner?: true} = first
    assert %{votes: 2, percentage: 50.0, rank: 1, winner?: true} = second
    assert %{votes: 0, rank: 3, winner?: false} = third
    assert third.percentage == 0.0
  end

  test "uses ballots as the support-rate denominator for multiple-choice polls", %{
    actor: actor
  } do
    fixture =
      open_poll!(actor, "Multiple-choice results", 2, %{
        selection_mode: :multiple,
        minimum_selections: 2,
        maximum_selections: 2
      })

    submit_options!(fixture, 0, [fixture.first, fixture.second])
    submit_options!(fixture, 1, [fixture.first, fixture.third])

    result = Results.for_poll(fixture.poll)

    assert result.selection_mode == :multiple
    assert result.ballot_count == 2
    assert result.total_selections == 4
    assert result.eligible_count == 2
    assert result.turnout_percentage == 100.0

    assert [first, second, third] = result.options
    assert %{option: %{label: "Alpha"}, votes: 2, percentage: 100.0} = first
    assert %{option: %{label: "Beta"}, votes: 1, percentage: 50.0} = second
    assert %{option: %{label: "Gamma"}, votes: 1, percentage: 50.0} = third
    assert Enum.sum(Enum.map(result.options, & &1.percentage)) == 200.0
  end

  test "publishes only closed polls and cannot publish twice", %{actor: actor} do
    fixture = open_poll!(actor, "Publication", 1)

    assert {:error, open_error} =
             Ash.update(fixture.poll, %{}, action: :publish_results, actor: actor)

    assert Exception.message(open_error) =~ "must be closed"

    closed = Ash.update!(fixture.poll, %{}, action: :close, actor: actor)
    published = Ash.update!(closed, %{}, action: :publish_results, actor: actor)

    assert published.results_published_at

    assert {:error, duplicate_error} =
             Ash.update(published, %{}, action: :publish_results, actor: actor)

    assert Exception.message(duplicate_error) =~ "already been published"
  end

  test "status and result events are isolated by poll", %{actor: actor} do
    first = open_poll!(actor, "Subscribed poll", 1)
    second = open_poll!(actor, "Other event poll", 1)
    :ok = Events.subscribe(first.poll.id)

    submit!(second, 0, second.first)
    refute_receive {:poll_results_changed, _poll_id}

    submit!(first, 0, first.first)
    assert_receive {:poll_results_changed, poll_id}
    assert poll_id == first.poll.id

    Ash.update!(second.poll, %{}, action: :close, actor: actor)
    refute_receive {:poll_status_changed, _poll_id, _status, _published_at}

    Ash.update!(first.poll, %{}, action: :close, actor: actor)
    assert_receive {:poll_status_changed, poll_id, :closed, nil}
    assert poll_id == first.poll.id
  end

  defp open_poll!(actor, title, member_count, poll_attributes \\ %{}) do
    poll =
      Ash.create!(
        Poll,
        Map.put(poll_attributes, :title, title),
        actor: actor
      )

    first = Ash.create!(Option, %{poll_id: poll.id, label: "Alpha", position: 1}, actor: actor)
    second = Ash.create!(Option, %{poll_id: poll.id, label: "Beta", position: 2}, actor: actor)
    third = Ash.create!(Option, %{poll_id: poll.id, label: "Gamma", position: 3}, actor: actor)

    grants =
      Enum.map(1..member_count, fn index ->
        member = Ash.create!(Member, %{name: "Voter #{title} #{index}"}, actor: actor)
        {_eligibility, grant} = Electorate.include_member(poll, member, actor)
        grant
      end)

    poll = Ash.update!(poll, %{}, action: :open, actor: actor)
    %{poll: poll, first: first, second: second, third: third, grants: grants}
  end

  defp submit!(fixture, grant_index, option) do
    submit_options!(fixture, grant_index, [option])
  end

  defp submit_options!(fixture, grant_index, options) do
    grant = Enum.at(fixture.grants, grant_index)

    {:ok, ballot} =
      Ballots.submit(fixture.poll.id, voting_token(grant), Enum.map(options, & &1.id))

    ballot
  end
end
