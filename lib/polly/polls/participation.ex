defmodule Polly.Polls.Participation do
  @moduledoc """
  Answers whether eligible members have submitted a final ballot for a poll.

  This boundary deliberately exposes participation only, never selections. The
  current implementation reads identified ballots; anonymous polls can replace
  that storage behind the same API with separate participation records.
  """

  require Ash.Query

  alias Polly.Polls.Ballot

  @doc "Returns whether one member has submitted a ballot for the poll."
  @spec submitted?(Ecto.UUID.t(), Ecto.UUID.t()) :: boolean()
  def submitted?(poll_id, member_id) do
    Ballot
    |> Ash.Query.filter(poll_id == ^poll_id and member_id == ^member_id)
    |> Ash.exists?(authorize?: false)
  end

  @doc "Returns the IDs of members who have submitted ballots for the poll."
  @spec submitted_member_ids(Ecto.UUID.t(), term()) :: MapSet.t(Ecto.UUID.t())
  def submitted_member_ids(poll_id, actor) do
    Ballot
    |> Ash.Query.filter(poll_id == ^poll_id)
    |> Ash.Query.select([:member_id])
    |> Ash.read!(actor: actor)
    |> MapSet.new(& &1.member_id)
  end
end
