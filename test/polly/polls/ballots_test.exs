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
    assert ballot.privacy_mode == :identified
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

  test "anonymous submission records participation without ballot identity", %{actor: actor} do
    %{poll: poll, member: member, grant: grant, option: option} = anonymous_open_poll!(actor)

    assert {:ok, ballot} = Ballots.submit(poll.id, voting_token(grant), [option.id])
    assert ballot.poll_id == poll.id
    assert ballot.privacy_mode == :anonymous
    assert is_nil(ballot.member_id)

    participation =
      Participation
      |> Ash.Query.filter(poll_id == ^poll.id and member_id == ^member.id)
      |> Ash.read_one!(authorize?: false)

    assert participation.participated_at

    [selection] =
      Selection
      |> Ash.Query.filter(ballot_id == ^ballot.id)
      |> Ash.read!(authorize?: false)

    refute Map.has_key?(Map.from_struct(ballot), :access_grant_id)
    refute Map.has_key?(Map.from_struct(ballot), :participation_id)
    refute Map.has_key?(Map.from_struct(selection), :member_id)
    refute Map.has_key?(Map.from_struct(selection), :access_grant_id)
    refute Map.has_key?(Map.from_struct(selection), :participation_id)
  end

  test "ballot privacy snapshots enforce member identity rules", %{actor: actor} do
    poll = Ash.create!(Poll, %{title: "Privacy snapshot"}, actor: actor)
    member = Ash.create!(Member, %{name: "Privacy voter"}, actor: actor)

    assert {:error, identified_error} =
             Ash.create(
               Ballot,
               %{poll_id: poll.id, privacy_mode: :identified},
               action: :submit,
               authorize?: false
             )

    assert Exception.message(identified_error) =~ "required for an identified ballot"

    assert {:error, anonymous_error} =
             Ash.create(
               Ballot,
               %{poll_id: poll.id, member_id: member.id, privacy_mode: :anonymous},
               action: :submit,
               authorize?: false
             )

    assert Exception.message(anonymous_error) =~ "must be absent from an anonymous ballot"

    anonymous_ballot =
      Ash.create!(
        Ballot,
        %{poll_id: poll.id, privacy_mode: :anonymous},
        action: :submit,
        authorize?: false
      )

    assert anonymous_ballot.privacy_mode == :anonymous
    assert is_nil(anonymous_ballot.member_id)
  end

  test "the database rejects inconsistent ballot privacy and identity", %{actor: actor} do
    %{poll: poll, grant: grant, option: option} = open_poll!(actor, "Database privacy invariant")
    assert {:ok, ballot} = Ballots.submit(poll.id, voting_token(grant), [option.id])

    assert {:error, %Exqlite.Error{message: message}} =
             Polly.Repo.query(
               "UPDATE poll_ballots SET privacy_mode = 'anonymous' WHERE id = ?",
               [ballot.id]
             )

    assert message =~ "poll_ballots_privacy_member_check"

    assert {:error, %Exqlite.Error{message: message}} =
             Polly.Repo.query(
               "UPDATE poll_ballots SET member_id = NULL WHERE id = ?",
               [ballot.id]
             )

    assert message =~ "poll_ballots_privacy_member_check"
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

  test "participation uniqueness allows only one concurrent anonymous submission", %{actor: actor} do
    %{poll: poll, grant: grant, option: option} = anonymous_open_poll!(actor, "Anonymous race")

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

    [ballot] =
      Ballot
      |> Ash.Query.filter(poll_id == ^poll.id)
      |> Ash.read!(authorize?: false)

    assert ballot.privacy_mode == :anonymous
    assert is_nil(ballot.member_id)
  end

  test "a reissued grant cannot submit after anonymous participation", %{actor: actor} do
    %{poll: poll, grant: grant, option: option, other_option: other_option} =
      anonymous_open_poll!(actor, "Anonymous reissue")

    assert {:ok, _ballot} = Ballots.submit(poll.id, voting_token(grant), [option.id])

    reissued_grant = Electorate.reissue(grant, actor)

    assert {:error, :already_submitted} =
             Ballots.submit(poll.id, voting_token(reissued_grant), [other_option.id])

    assert 1 == participation_count(poll.id)
    assert 1 == Ballot |> Ash.Query.filter(poll_id == ^poll.id) |> Ash.count!(authorize?: false)
    assert 1 == Selection |> Ash.count!(authorize?: false)
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

  test "a failed anonymous selection rolls back participation and ballot", %{actor: actor} do
    %{poll: poll, grant: grant, option: option} =
      anonymous_open_poll!(actor, "Anonymous rollback")

    trigger = "force_anonymous_selection_failure_#{System.unique_integer([:positive])}"

    Polly.Repo.query!("""
    CREATE TRIGGER #{trigger}
    BEFORE INSERT ON poll_selections
    WHEN NEW.option_id = '#{option.id}'
    BEGIN
      SELECT RAISE(ABORT, 'forced_anonymous_selection_failure');
    END
    """)

    on_exit(fn -> Polly.Repo.query!("DROP TRIGGER IF EXISTS #{trigger}") end)

    assert {:error, _reason} = Ballots.submit(poll.id, voting_token(grant), [option.id])
    assert 0 == participation_count(poll.id)
    assert 0 == Ballot |> Ash.Query.filter(poll_id == ^poll.id) |> Ash.count!(authorize?: false)
    assert 0 == Selection |> Ash.count!(authorize?: false)
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

  defp anonymous_open_poll!(actor, title \\ "Anonymous ballot") do
    fixture = draft_poll!(actor, title)

    poll =
      fixture.poll
      |> Ash.update!(%{privacy_mode: :anonymous}, action: :update_draft, actor: actor)
      |> Ash.update!(%{}, action: :open, actor: actor)

    %{fixture | poll: poll}
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
