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
    assert is_nil(grant.token)
    assert is_binary(grant.token_digest)
    assert is_binary(grant.credential_nonce)
    assert grant.credential_version == 1
    assert grant.credential_issued_at
    assert byte_size(voting_token(grant)) >= 40
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

    assert {:ok, resolved} = AccessGrant.resolve(first_poll.id, voting_token(grant))

    assert resolved.id == grant.id

    assert {:error, %Ash.Error.Invalid{}} =
             AccessGrant.resolve(second_poll.id, voting_token(grant))

    Ash.update!(grant, %{}, action: :revoke, actor: actor)

    assert {:error, %Ash.Error.Invalid{}} =
             AccessGrant.resolve(first_poll.id, voting_token(grant))
  end

  test "reissuing revokes the old token and creates a new grant", %{actor: actor} do
    poll = create_poll!(actor, "Team Theme")
    member = Ash.create!(Member, %{name: "Jamie Rivera"}, actor: actor)
    {_eligibility, old_grant} = Electorate.include_member(poll, member, actor)

    new_grant = Electorate.reissue(old_grant, actor)
    old_grant = Ash.get!(AccessGrant, old_grant.id, actor: actor)

    assert old_grant.revoked_at
    assert new_grant.id != old_grant.id
    assert voting_token(new_grant) != voting_token(old_grant)
  end

  test "legacy plaintext grants continue to resolve during migration", %{actor: actor} do
    poll = create_poll!(actor, "Legacy Poll")
    member = Ash.create!(Member, %{name: "Legacy voter"}, actor: actor)
    {_eligibility, grant} = Electorate.include_member(poll, member, actor)
    legacy_token = "legacy-" <> Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)

    Polly.Repo.query!(
      "UPDATE poll_access_grants SET token = ?, token_digest = NULL, credential_nonce = NULL, credential_version = 0, credential_issued_at = NULL WHERE id = ?",
      [legacy_token, grant.id]
    )

    assert {:ok, resolved} = AccessGrant.resolve(poll.id, legacy_token)
    assert resolved.id == grant.id
    assert resolved.token == legacy_token
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
      %{title: title},
      actor: actor
    )
  end
end
