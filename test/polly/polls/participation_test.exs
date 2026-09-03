defmodule Polly.Polls.ParticipationTest do
  use Polly.DataCase

  alias Polly.Accounts.User
  alias Polly.Members.Member
  alias Polly.Polls.{Participation, Poll}

  setup do
    actor =
      Ash.create!(
        User,
        %{
          email: "participation-admin-#{System.unique_integer([:positive])}@example.com",
          password: "secure-password",
          password_confirmation: "secure-password"
        },
        action: :register_with_password,
        authorize?: false
      )

    member = Ash.create!(Member, %{name: "Jamie Rivera"}, actor: actor)
    other_member = Ash.create!(Member, %{name: "Morgan Lee"}, actor: actor)
    poll = Ash.create!(Poll, %{title: "Board Election"}, actor: actor)
    other_poll = Ash.create!(Poll, %{title: "Policy Vote"}, actor: actor)

    %{
      actor: actor,
      member: member,
      other_member: other_member,
      poll: poll,
      other_poll: other_poll
    }
  end

  test "submitted?/2 is scoped to both the poll and member", context do
    refute Participation.submitted?(context.poll.id, context.member.id)

    Ash.create!(
      Participation,
      %{poll_id: context.poll.id, member_id: context.member.id},
      action: :record,
      authorize?: false
    )

    assert Participation.submitted?(context.poll.id, context.member.id)
    refute Participation.submitted?(context.poll.id, context.other_member.id)
    refute Participation.submitted?(context.other_poll.id, context.member.id)
  end

  test "submitted_member_ids/2 returns participation without selections", context do
    Ash.create!(
      Participation,
      %{poll_id: context.poll.id, member_id: context.member.id},
      action: :record,
      authorize?: false
    )

    assert Participation.submitted_member_ids(context.poll.id, context.actor) ==
             MapSet.new([context.member.id])
  end

  test "permits only one participation per poll and member", context do
    attributes = %{poll_id: context.poll.id, member_id: context.member.id}

    participation =
      Ash.create!(Participation, attributes, action: :record, authorize?: false)

    assert participation.participated_at

    assert {:error, error} =
             Ash.create(Participation, attributes, action: :record, authorize?: false)

    assert Exception.message(error) =~ "has already been taken"
  end
end
