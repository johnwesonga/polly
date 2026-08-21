defmodule Polly.Polls.AccessGrantTest do
  use Polly.DataCase

  require Ash.Query

  alias Polly.Accounts.User
  alias Polly.Members.Member
  alias Polly.Polls.{AccessGrant, Eligibility, Electorate, Option, Poll}

  setup do
    actor =
      Ash.create!(
        User,
        %{
          email: "access-admin-#{System.unique_integer([:positive])}@example.com",
          password: "secure-password",
          password_confirmation: "secure-password"
        },
        action: :register_with_password,
        authorize?: false
      )

    %{actor: actor}
  end

  test "selecting a member snapshots eligibility and issues a grant", %{actor: actor} do
    poll = create_poll!(actor, "Team Theme")
    member = Ash.create!(Member, %{name: "Jamie Rivera"}, actor: actor)

    {eligibility, grant} = Electorate.include_member(poll, member, actor)

    assert eligibility.poll_id == poll.id
    assert eligibility.member_id == member.id
    assert grant.poll_id == poll.id
    assert grant.member_id == member.id
    assert byte_size(grant.token) >= 40
  end

  test "a grant cannot be issued to an ineligible member", %{actor: actor} do
    poll = create_poll!(actor, "Team Theme")
    member = Ash.create!(Member, %{name: "Jamie Rivera"}, actor: actor)

    assert {:error, error} =
             Ash.create(AccessGrant, %{poll_id: poll.id, member_id: member.id}, actor: actor)

    assert Exception.message(error) =~ "not eligible for this poll"
  end

  test "tokens are scoped to their poll and revoked tokens no longer resolve", %{actor: actor} do
    first_poll = create_poll!(actor, "First Poll")
    second_poll = create_poll!(actor, "Second Poll")
    member = Ash.create!(Member, %{name: "Jamie Rivera"}, actor: actor)
    {_eligibility, grant} = Electorate.include_member(first_poll, member, actor)

    assert {:ok, resolved} = AccessGrant.resolve(first_poll.id, grant.token)

    assert resolved.id == grant.id

    assert {:error, %Ash.Error.Invalid{}} = AccessGrant.resolve(second_poll.id, grant.token)

    Ash.update!(grant, %{}, action: :revoke, actor: actor)

    assert {:error, %Ash.Error.Invalid{}} = AccessGrant.resolve(first_poll.id, grant.token)
  end

  test "reissuing revokes the old token and creates a new grant", %{actor: actor} do
    poll = create_poll!(actor, "Team Theme")
    member = Ash.create!(Member, %{name: "Jamie Rivera"}, actor: actor)
    {_eligibility, old_grant} = Electorate.include_member(poll, member, actor)

    new_grant = Electorate.reissue(old_grant, actor)
    old_grant = Ash.get!(AccessGrant, old_grant.id, actor: actor)

    assert old_grant.revoked_at
    assert new_grant.id != old_grant.id
    assert new_grant.token != old_grant.token
  end

  test "eligibility is frozen after the poll opens", %{actor: actor} do
    poll = create_poll!(actor, "Team Theme")
    member = Ash.create!(Member, %{name: "Jamie Rivera"}, actor: actor)

    eligibility =
      Ash.create!(Eligibility, %{poll_id: poll.id, member_id: member.id}, actor: actor)

    Ash.create!(Option, %{poll_id: poll.id, label: "One", position: 1}, actor: actor)
    Ash.create!(Option, %{poll_id: poll.id, label: "Two", position: 2}, actor: actor)

    poll = Ash.update!(poll, %{}, action: :open, actor: actor)

    assert {:error, error} = Ash.destroy(eligibility, actor: actor)
    assert Exception.message(error) =~ "frozen"
    assert poll.status == :open
  end

  defp create_poll!(actor, title) do
    Ash.create!(
      Poll,
      %{title: title, slug: Polly.Polls.Slug.from_title(title)},
      actor: actor
    )
  end
end
