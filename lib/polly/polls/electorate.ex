defmodule Polly.Polls.Electorate do
  @moduledoc "Manages a poll's eligibility snapshot and revocable access grants."

  require Ash.Query

  alias Polly.Polls.{AccessGrant, Eligibility, Poll}

  def include_member(%Poll{status: :draft} = poll, member, actor) do
    {:ok, result} =
      Polly.Repo.transaction(fn ->
        eligibility =
          Ash.create!(Eligibility, %{poll_id: poll.id, member_id: member.id}, actor: actor)

        grant =
          Ash.create!(AccessGrant, %{poll_id: poll.id, member_id: member.id}, actor: actor)

        {eligibility, grant}
      end)

    result
  end

  def exclude_member(%Poll{status: :draft}, %Eligibility{} = eligibility, actor) do
    {:ok, result} =
      Polly.Repo.transaction(fn ->
        eligibility.poll_id
        |> active_grants(eligibility.member_id, actor)
        |> Enum.each(&Ash.update!(&1, %{}, action: :revoke, actor: actor))

        Ash.destroy!(eligibility, actor: actor)
      end)

    result
  end

  def reissue(%AccessGrant{} = grant, actor) do
    {:ok, result} =
      Polly.Repo.transaction(fn ->
        Ash.update!(grant, %{}, action: :revoke, actor: actor)

        Ash.create!(
          AccessGrant,
          %{poll_id: grant.poll_id, member_id: grant.member_id, expires_at: grant.expires_at},
          actor: actor
        )
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
