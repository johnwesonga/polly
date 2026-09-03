defmodule Polly.Polls.BallotsTest do
  use Polly.DataCase

  require Ash.Query

  alias Polly.Accounts.User
  alias Polly.Members.Member

  alias Polly.Polls.{
    Ballot,
    Ballots,
    Eligibility,
    Electorate,
    Option,
    Participation,
    Poll,
    Selection
  }

  setup do
    actor =
      Ash.create!(
        User,
        %{
          email: "ballot-admin-#{System.unique_integer([:positive])}@example.com",
          password: "secure-password",
          password_confirmation: "secure-password"
        },
        action: :register_with_password,
        authorize?: false
      )

    %{actor: actor}
  end

  test "submits one final text-option ballot from the grant identity", %{actor: actor} do
    %{poll: poll, member: member, grant: grant, option: option} = open_poll!(actor)

    assert {:ok, ballot} = Ballots.submit(poll.id, voting_token(grant), [option.id])
    assert ballot.poll_id == poll.id
    assert ballot.member_id == member.id
    assert ballot.submitted_at

    participation =
      Participation
      |> Ash.Query.filter(poll_id == ^poll.id and member_id == ^member.id)
      |> Ash.read_one!(authorize?: false)

    assert participation.participated_at

    selection =
      Selection
      |> Ash.Query.filter(ballot_id == ^ballot.id)
      |> Ash.read_one!(authorize?: false)

    assert selection.option_id == option.id
  end

  test "selection storage permits distinct options but rejects the same option twice", %{
    actor: actor
  } do
    %{poll: poll, grant: grant, option: option, other_option: other_option} = open_poll!(actor)
    assert {:ok, ballot} = Ballots.submit(poll.id, voting_token(grant), [option.id])

    assert {:ok, second_selection} =
             Ash.create(
               Selection,
               %{ballot_id: ballot.id, option_id: other_option.id},
               action: :select
             )

    assert second_selection.option_id == other_option.id

    assert {:error, duplicate_error} =
             Ash.create(
               Selection,
               %{ballot_id: ballot.id, option_id: option.id},
               action: :select
             )

    assert Exception.message(duplicate_error) =~ "has already been taken"

    assert 2 ==
             Selection
             |> Ash.Query.filter(ballot_id == ^ballot.id)
             |> Ash.count!(authorize?: false)
  end

  test "single-choice polls require exactly one distinct option", %{actor: actor} do
    %{poll: poll, grant: grant, option: option, other_option: other_option} = open_poll!(actor)

    assert {:error, :too_few_selections} = Ballots.submit(poll.id, voting_token(grant), [])

    assert {:error, :too_many_selections} =
             Ballots.submit(poll.id, voting_token(grant), [option.id, other_option.id])

    assert {:error, :duplicate_options} =
             Ballots.submit(poll.id, voting_token(grant), [option.id, option.id])

    assert 0 == Ballot |> Ash.Query.filter(poll_id == ^poll.id) |> Ash.count!(authorize?: false)
    assert 0 == participation_count(poll.id)
  end

  test "stores every valid option atomically for a poll range", %{actor: actor} do
    %{poll: poll, grant: grant, option: option, other_option: other_option} = open_poll!(actor)
    set_selection_range!(poll, 2, 2)

    assert {:ok, ballot} =
             Ballots.submit(poll.id, voting_token(grant), [option.id, other_option.id])

    selected_ids =
      Selection
      |> Ash.Query.filter(ballot_id == ^ballot.id)
      |> Ash.read!(authorize?: false)
      |> Enum.map(& &1.option_id)
      |> MapSet.new()

    assert selected_ids == MapSet.new([option.id, other_option.id])
  end

  test "does not create a ballot when any submitted option is invalid", %{actor: actor} do
    %{poll: poll, grant: grant, option: option} = open_poll!(actor)
    set_selection_range!(poll, 2, 2)

    assert {:error, :option_not_in_poll} =
             Ballots.submit(poll.id, voting_token(grant), [option.id, Ecto.UUID.generate()])

    assert 0 == Ballot |> Ash.Query.filter(poll_id == ^poll.id) |> Ash.count!(authorize?: false)
    assert 0 == Selection |> Ash.count!(authorize?: false)
    assert 0 == participation_count(poll.id)
  end

  test "rejects invalid, cross-poll, and revoked grants", %{actor: actor} do
    first = open_poll!(actor, "First ballot")
    second = open_poll!(actor, "Second ballot")

    assert {:error, :invalid_grant} =
             Ballots.submit(first.poll.id, "not-a-grant", [first.option.id])

    assert {:error, :invalid_grant} =
             Ballots.submit(second.poll.id, voting_token(first.grant), [second.option.id])

    Ash.update!(first.grant, %{}, action: :revoke, actor: actor)

    assert {:error, :invalid_grant} =
             Ballots.submit(first.poll.id, voting_token(first.grant), [first.option.id])
  end

  test "rejects an ineligible grant member", %{actor: actor} do
    %{poll: poll, grant: grant, option: option} = fixture = draft_poll!(actor, "Eligibility")

    backup_member = Ash.create!(Member, %{name: "Backup voter"}, actor: actor)
    Electorate.include_member(poll, backup_member, actor)

    eligibility =
      Eligibility
      |> Ash.Query.filter(poll_id == ^poll.id and member_id == ^fixture.member.id)
      |> Ash.read_one!(authorize?: false)

    Ash.destroy!(eligibility, authorize?: false)
    poll = Ash.update!(poll, %{}, action: :open, actor: actor)

    assert {:error, :member_not_eligible} =
             Ballots.submit(poll.id, voting_token(grant), [option.id])
  end

  test "rejects an option belonging to another poll", %{actor: actor} do
    first = open_poll!(actor, "Option source")
    second = open_poll!(actor, "Submitting poll")

    assert {:error, :option_not_in_poll} =
             Ballots.submit(second.poll.id, voting_token(second.grant), [first.option.id])
  end

  test "requires an open poll", %{actor: actor} do
    %{poll: poll, grant: grant, option: option} = draft_poll!(actor, "Draft ballot")

    assert {:error, :poll_not_open} = Ballots.submit(poll.id, voting_token(grant), [option.id])
  end

  test "rejects duplicate final submissions without adding another selection", %{actor: actor} do
    %{poll: poll, grant: grant, option: option, other_option: other_option} = open_poll!(actor)

    assert {:ok, _ballot} = Ballots.submit(poll.id, voting_token(grant), [option.id])

    assert {:error, :already_submitted} =
             Ballots.submit(poll.id, voting_token(grant), [other_option.id])

    assert 1 ==
             Ballot
             |> Ash.Query.filter(poll_id == ^poll.id)
             |> Ash.count!(authorize?: false)

    assert 1 == Selection |> Ash.count!(authorize?: false)
    assert 1 == participation_count(poll.id)
  end

  test "the database identity allows only one concurrent submission", %{actor: actor} do
    %{poll: poll, grant: grant, option: option} = open_poll!(actor)

    results =
      1..2
      |> Task.async_stream(
        fn _ -> Ballots.submit(poll.id, voting_token(grant), [option.id]) end,
        max_concurrency: 2,
        ordered: false,
        timeout: :infinity
      )
      |> Enum.map(fn {:ok, result} -> result end)

    assert 1 == Enum.count(results, &match?({:ok, _ballot}, &1))
    assert 1 == Enum.count(results, &match?({:error, :already_submitted}, &1))
    assert 1 == participation_count(poll.id)
  end

  test "a failed selection insert rolls back the ballot and earlier selections", %{actor: actor} do
    %{poll: poll, grant: grant, option: option, other_option: other_option} = open_poll!(actor)
    set_selection_range!(poll, 2, 2)
    trigger = "force_selection_failure_#{System.unique_integer([:positive])}"

    Polly.Repo.query!("""
    CREATE TRIGGER #{trigger}
    BEFORE INSERT ON poll_selections
    WHEN NEW.option_id = '#{other_option.id}'
    BEGIN
      SELECT RAISE(ABORT, 'forced_selection_failure');
    END
    """)

    on_exit(fn -> Polly.Repo.query!("DROP TRIGGER IF EXISTS #{trigger}") end)

    assert {:error, _reason} =
             Ballots.submit(poll.id, voting_token(grant), [option.id, other_option.id])

    assert 0 == Ballot |> Ash.Query.filter(poll_id == ^poll.id) |> Ash.count!(authorize?: false)
    assert 0 == Selection |> Ash.count!(authorize?: false)
    assert 0 == participation_count(poll.id)
  end

  defp participation_count(poll_id) do
    Participation
    |> Ash.Query.filter(poll_id == ^poll_id)
    |> Ash.count!(authorize?: false)
  end

  defp open_poll!(actor, title \\ "Final ballot") do
    fixture = draft_poll!(actor, title)
    %{fixture | poll: Ash.update!(fixture.poll, %{}, action: :open, actor: actor)}
  end

  defp set_selection_range!(poll, minimum, maximum) do
    Polly.Repo.query!(
      "UPDATE polls SET selection_mode = 'multiple', minimum_selections = ?, maximum_selections = ? WHERE id = ?",
      [minimum, maximum, poll.id]
    )
  end

  defp draft_poll!(actor, title) do
    poll =
      Ash.create!(
        Poll,
        %{
          title: title
        },
        actor: actor
      )

    option = Ash.create!(Option, %{poll_id: poll.id, label: "Alpha", position: 1}, actor: actor)

    other_option =
      Ash.create!(Option, %{poll_id: poll.id, label: "Beta", position: 2}, actor: actor)

    member =
      Ash.create!(
        Member,
        %{name: "Voter #{System.unique_integer([:positive])}"},
        actor: actor
      )

    {_eligibility, grant} = Electorate.include_member(poll, member, actor)

    %{poll: poll, member: member, grant: grant, option: option, other_option: other_option}
  end
end
