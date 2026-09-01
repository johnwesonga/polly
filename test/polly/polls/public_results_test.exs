defmodule Polly.Polls.PublicResultsTest do
  use Polly.DataCase

  require Ash.Query

  alias Polly.Accounts.User
  alias Polly.Audit.Event
  alias Polly.Members.Member
  alias Polly.Polls.{Ballots, Electorate, Option, Poll, PublicResults}

  setup do
    actor =
      Ash.create!(
        User,
        %{
          email: "public-results-#{System.unique_integer([:positive])}@example.com",
          password: "secure-password",
          password_confirmation: "secure-password"
        },
        action: :register_with_password,
        authorize?: false
      )

    %{actor: actor}
  end

  test "polls default to credentialed results and closed polls can change visibility", %{
    actor: actor
  } do
    fixture = configured_poll!(actor, "Private by default")
    assert fixture.poll.result_visibility == :credentialed

    assert {:error, draft_error} =
             Ash.update(fixture.poll, %{}, action: :make_results_public, actor: actor)

    assert Exception.message(draft_error) =~ "must be closed"

    closed =
      fixture.poll
      |> Ash.update!(%{}, action: :open, actor: actor)
      |> Ash.update!(%{}, action: :close, actor: actor)

    public = Ash.update!(closed, %{}, action: :make_results_public, actor: actor)
    assert public.result_visibility == :public

    credentialed =
      Ash.update!(public, %{}, action: :make_results_credentialed, actor: actor)

    assert credentialed.result_visibility == :credentialed

    events =
      Event
      |> Ash.Query.filter(
        action == "poll.results_made_public" or action == "poll.results_made_credentialed"
      )
      |> Ash.Query.sort(occurred_at: :asc)
      |> Ash.read!(authorize?: false)

    assert Enum.map(events, & &1.action) == [
             "poll.results_made_public",
             "poll.results_made_credentialed"
           ]

    assert Enum.map(events, & &1.metadata) == [
             %{"new_visibility" => "public", "old_visibility" => "credentialed"},
             %{"new_visibility" => "credentialed", "old_visibility" => "public"}
           ]
  end

  test "returns only a safe aggregate projection for a published public poll", %{actor: actor} do
    fixture = configured_poll!(actor, "Shareable results")
    opened = Ash.update!(fixture.poll, %{}, action: :open, actor: actor)

    assert {:ok, _ballot} =
             Ballots.submit(opened.id, voting_token(fixture.grant), [fixture.option.id])

    published =
      opened
      |> Ash.update!(%{}, action: :close, actor: actor)
      |> Ash.update!(%{}, action: :publish_results, actor: actor)
      |> Ash.update!(%{}, action: :make_results_public, actor: actor)

    assert {:ok, result} = PublicResults.fetch_by_slug(published.slug)
    assert result.poll_id == published.id
    assert result.ballot_count == 1
    assert result.eligible_count == 1
    assert result.total_selections == 1
    assert [%{id: option_id, label: "First option", selections: 1}, _second] = result.options
    assert option_id == fixture.option.id

    refute Map.has_key?(result, :eligibilities)
    refute Map.has_key?(result, :access_grants)
    refute Map.has_key?(result, :ballots)
    refute Map.has_key?(result, :members)
    refute Map.has_key?(result, :token)
  end

  test "fails closed for every unavailable state", %{actor: actor} do
    fixture = configured_poll!(actor, "Unavailable results")
    assert {:error, :not_found} = PublicResults.fetch_by_slug(fixture.poll.slug)

    opened = Ash.update!(fixture.poll, %{}, action: :open, actor: actor)
    assert {:error, :not_found} = PublicResults.fetch_by_slug(opened.slug)

    closed = Ash.update!(opened, %{}, action: :close, actor: actor)
    public_unpublished = Ash.update!(closed, %{}, action: :make_results_public, actor: actor)
    assert {:error, :not_found} = PublicResults.fetch_by_slug(public_unpublished.slug)

    published = Ash.update!(public_unpublished, %{}, action: :publish_results, actor: actor)
    assert {:ok, _result} = PublicResults.fetch_by_slug(published.slug)

    withdrawn =
      Ash.update!(published, %{}, action: :make_results_credentialed, actor: actor)

    assert {:error, :not_found} = PublicResults.fetch_by_slug(withdrawn.slug)
    assert {:error, :not_found} = PublicResults.fetch_by_slug("unknown-poll")
  end

  defp configured_poll!(actor, title) do
    poll = Ash.create!(Poll, %{title: title}, actor: actor)

    option =
      Ash.create!(Option, %{poll_id: poll.id, label: "First option", position: 1}, actor: actor)

    Ash.create!(Option, %{poll_id: poll.id, label: "Second option", position: 2}, actor: actor)
    member = Ash.create!(Member, %{name: "Public results voter"}, actor: actor)
    {_eligibility, grant} = Electorate.include_member(poll, member, actor)

    %{poll: poll, option: option, grant: grant}
  end
end
