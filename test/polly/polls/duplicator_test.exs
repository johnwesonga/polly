defmodule Polly.Polls.DuplicatorTest do
  use Polly.DataCase

  require Ash.Query

  alias Polly.Accounts.User
  alias Polly.Members.Member

  alias Polly.Polls.{
    AccessGrant,
    Ballot,
    Ballots,
    Duplicator,
    Electorate,
    Eligibility,
    Option,
    Poll,
    Selection
  }

  setup do
    actor =
      Ash.create!(
        User,
        %{
          email: "duplicate-admin-#{System.unique_integer([:positive])}@example.com",
          password: "secure-password",
          password_confirmation: "secure-password"
        },
        action: :register_with_password,
        authorize?: false
      )

    %{actor: actor}
  end

  test "duplicates only poll details into an independent draft", %{actor: actor} do
    fixture = configured_poll!(actor, "Annual Theme")
    opened = Ash.update!(fixture.poll, %{}, action: :open, actor: actor)
    {:ok, _ballot} = Ballots.submit(opened.id, fixture.grant.token, fixture.option.id)
    source = Ash.update!(opened, %{}, action: :close, actor: actor)
    source = Ash.update!(source, %{}, action: :publish_results, actor: actor)

    assert {:ok, result} = Duplicator.duplicate(source, actor)
    duplicate = result.poll

    assert result.source_title == source.title
    assert result.options_copied == 0
    assert result.members_copied == 0
    assert result.members_skipped == 0
    assert duplicate.id != source.id
    assert duplicate.title == "Copy of Annual Theme"
    assert duplicate.description == source.description
    assert duplicate.selection_mode == source.selection_mode
    assert duplicate.slug == "copy-of-annual-theme"
    assert duplicate.status == :draft
    refute duplicate.opened_at
    refute duplicate.closed_at
    refute duplicate.results_published_at

    assert count_for(Option, duplicate.id) == 0
    assert count_for(Eligibility, duplicate.id) == 0
    assert count_for(AccessGrant, duplicate.id) == 0
    assert count_for(Ballot, duplicate.id) == 0
    assert Ash.count!(Selection, authorize?: false) == 1

    unchanged = Ash.get!(Poll, source.id, actor: actor)
    assert unchanged.status == :closed
    assert unchanged.results_published_at == source.results_published_at
  end

  test "duplicates draft, open, and closed source polls", %{actor: actor} do
    draft = configured_poll!(actor, "Draft Source").poll
    open = configured_poll!(actor, "Open Source").poll |> open!(actor)
    closed = configured_poll!(actor, "Closed Source").poll |> open!(actor) |> close!(actor)

    for source <- [draft, open, closed] do
      assert {:ok, %{poll: duplicate}} = Duplicator.duplicate(source, actor)
      assert duplicate.status == :draft
      assert duplicate.title == "Copy of #{source.title}"
    end
  end

  test "repeated copies receive unique slugs", %{actor: actor} do
    source = configured_poll!(actor, "Repeatable").poll

    assert {:ok, %{poll: first}} = Duplicator.duplicate(source, actor)
    assert {:ok, %{poll: second}} = Duplicator.duplicate(source, actor)
    assert {:ok, %{poll: third}} = Duplicator.duplicate(source, actor)

    assert [first.slug, second.slug, third.slug] == [
             "copy-of-repeatable",
             "copy-of-repeatable-2",
             "copy-of-repeatable-3"
           ]
  end

  test "duplicating a duplicate normalizes its title and slug", %{actor: actor} do
    source = configured_poll!(actor, "For One").poll
    assert {:ok, %{poll: first}} = Duplicator.duplicate(source, actor)
    assert {:ok, %{poll: second}} = Duplicator.duplicate(first, actor)

    assert first.title == "Copy of For One"
    assert second.title == "Copy of For One"
    assert first.slug == "copy-of-for-one"
    assert second.slug == "copy-of-for-one-2"
  end

  test "concurrent copies receive distinct slugs", %{actor: actor} do
    source = configured_poll!(actor, "Concurrent Copy").poll

    duplicates =
      1..2
      |> Task.async_stream(
        fn _ -> Duplicator.duplicate(source, actor) end,
        max_concurrency: 2,
        ordered: false,
        timeout: :infinity
      )
      |> Enum.map(fn {:ok, {:ok, %{poll: duplicate}}} -> duplicate end)

    assert duplicates |> Enum.map(& &1.slug) |> Enum.sort() == [
             "copy-of-concurrent-copy",
             "copy-of-concurrent-copy-2"
           ]
  end

  test "copy title and slug stay within resource limits", %{actor: actor} do
    source =
      Ash.create!(
        Poll,
        %{
          title: String.duplicate("A", 160),
          description: "Long configuration",
          slug: String.duplicate("a", 180)
        },
        actor: actor
      )

    assert {:ok, %{poll: duplicate}} = Duplicator.duplicate(source, actor)
    assert String.length(duplicate.title) == 160
    assert String.starts_with?(duplicate.title, "Copy of ")
    assert duplicate.slug == Polly.Polls.Slug.from_title(duplicate.title)
    assert String.length(duplicate.slug) <= 180
  end

  test "requires an authenticated actor", %{actor: actor} do
    source = configured_poll!(actor, "Protected Source").poll
    assert {:error, :actor_required} = Duplicator.duplicate(source, nil)
  end

  defp configured_poll!(actor, title) do
    poll =
      Ash.create!(
        Poll,
        %{title: title, description: "Reusable poll details", slug: slug(title)},
        actor: actor
      )

    option = Ash.create!(Option, %{poll_id: poll.id, label: "Alpha", position: 1}, actor: actor)
    Ash.create!(Option, %{poll_id: poll.id, label: "Beta", position: 2}, actor: actor)
    member = Ash.create!(Member, %{name: "Eligible member #{title}"}, actor: actor)
    {_eligibility, grant} = Electorate.include_member(poll, member, actor)

    %{poll: poll, option: option, grant: grant}
  end

  defp count_for(resource, poll_id) do
    resource
    |> Ash.Query.filter(poll_id == ^poll_id)
    |> Ash.count!(authorize?: false)
  end

  defp open!(poll, actor), do: Ash.update!(poll, %{}, action: :open, actor: actor)
  defp close!(poll, actor), do: Ash.update!(poll, %{}, action: :close, actor: actor)

  defp slug(title), do: Polly.Polls.Slug.from_title(title)
end
