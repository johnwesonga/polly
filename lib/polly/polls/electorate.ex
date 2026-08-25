defmodule Polly.Polls.Electorate do
  @moduledoc "Manages a poll's eligibility snapshot and revocable access grants."

  require Ash.Query

  alias Polly.Members.Member
  alias Polly.Polls.{AccessGrant, Eligibility, Poll}

  def include_member(%Poll{status: :draft} = poll, member, actor) do
    {:ok, result} =
      Polly.Repo.transaction(fn ->
        eligibility =
          Ash.create!(Eligibility, %{poll_id: poll.id, member_id: member.id}, actor: actor)

        grant =
          Ash.create!(AccessGrant, %{poll_id: poll.id, member_id: member.id}, actor: actor)

        Polly.Audit.append!(%{
          action: "poll_electorate.member_added",
          actor: actor,
          target: %{type: "member", id: member.id, label: member.name},
          poll_id: poll.id,
          metadata: %{member_id: member.id}
        })

        {eligibility, grant}
      end)

    result
  end

  def exclude_member(%Poll{status: :draft}, %Eligibility{} = eligibility, actor) do
    {:ok, result} =
      Polly.Repo.transaction(fn ->
        member = Ash.get!(Member, eligibility.member_id, actor: actor)

        eligibility.poll_id
        |> active_grants(eligibility.member_id, actor)
        |> Enum.each(&Ash.update!(&1, %{}, action: :revoke, actor: actor))

        result = Ash.destroy!(eligibility, actor: actor)

        Polly.Audit.append!(%{
          action: "poll_electorate.member_removed",
          actor: actor,
          target: %{type: "member", id: member.id, label: member.name},
          poll_id: eligibility.poll_id,
          metadata: %{member_id: member.id}
        })

        result
      end)

    result
  end

  def reissue(%AccessGrant{} = grant, actor) do
    {:ok, result} =
      Polly.Repo.transaction(fn ->
        member = Ash.get!(Member, grant.member_id, actor: actor)
        Ash.update!(grant, %{}, action: :revoke, actor: actor)

        new_grant =
          Ash.create!(
            AccessGrant,
            %{poll_id: grant.poll_id, member_id: grant.member_id, expires_at: grant.expires_at},
            actor: actor
          )

        Polly.Audit.append!(%{
          action: "poll_access_grant.reissued",
          actor: actor,
          target: %{type: "member", id: member.id, label: member.name},
          poll_id: grant.poll_id,
          metadata: %{
            member_id: member.id,
            old_grant_id: grant.id,
            new_grant_id: new_grant.id
          }
        })

        new_grant
      end)

    result
  end

  def issue(poll_id, member_id, actor) do
    {:ok, result} =
      Polly.Repo.transaction(fn ->
        member = Ash.get!(Member, member_id, actor: actor)
        grant = Ash.create!(AccessGrant, %{poll_id: poll_id, member_id: member_id}, actor: actor)

        Polly.Audit.append!(%{
          action: "poll_access_grant.issued",
          actor: actor,
          target: %{type: "member", id: member.id, label: member.name},
          poll_id: poll_id,
          metadata: %{member_id: member.id, grant_id: grant.id}
        })

        grant
      end)

    result
  end

  def revoke(%AccessGrant{} = grant, actor) do
    {:ok, result} =
      Polly.Repo.transaction(fn ->
        member = Ash.get!(Member, grant.member_id, actor: actor)
        revoked = Ash.update!(grant, %{}, action: :revoke, actor: actor)

        Polly.Audit.append!(%{
          action: "poll_access_grant.revoked",
          actor: actor,
          target: %{type: "member", id: member.id, label: member.name},
          poll_id: grant.poll_id,
          metadata: %{member_id: member.id, grant_id: grant.id}
        })

        revoked
      end)

    result
  end

  def active_grants(poll_id, member_id, actor) do
    AccessGrant
    |> Ash.Query.filter(poll_id == ^poll_id and member_id == ^member_id and is_nil(revoked_at))
    |> Ash.Query.sort(inserted_at: :desc)
    |> Ash.read!(actor: actor)
  end
end
