defmodule Polly.Polls.Ballots do
  @moduledoc "Transactional, token-authenticated ballot submission."

  require Ash.Query

  alias Polly.Polls.{AccessGrant, Ballot, Eligibility, Option, Participation, Poll, Selection}

  @type submission_error ::
          :invalid_grant
          | :poll_not_open
          | :member_not_eligible
          | :too_few_selections
          | :too_many_selections
          | :duplicate_options
          | :option_not_in_poll
          | :already_submitted

  @doc """
  Submits one final collection of selections using a poll-scoped access token.

  The member is always derived from the grant. All checks and inserts run in
  one transaction; participation uniqueness protects against racing calls.
  Identified ballots retain that member, while anonymous ballots omit it.

  Callers use the same option-ID list shape for single- and multiple-choice
  polls.
  """
  @spec submit(Ecto.UUID.t(), String.t(), [Ecto.UUID.t()]) ::
          {:ok, Ballot.t()} | {:error, submission_error() | term()}
  def submit(poll_id, token, option_ids) when is_list(option_ids) do
    case Polly.Repo.transaction(fn -> submit_in_transaction(poll_id, token, option_ids) end) do
      {:ok, ballot} ->
        Polly.Polls.Events.broadcast_results(poll_id)
        {:ok, ballot}

      {:error, reason} ->
        {:error, normalize_error(reason)}
    end
  end

  defp submit_in_transaction(poll_id, token, option_ids) do
    grant = fetch_grant!(poll_id, token)
    poll = fetch_open_poll!(poll_id)
    ensure_eligible!(poll_id, grant.member_id)
    ensure_distinct_options!(option_ids)
    ensure_selection_count!(poll, option_ids)
    ensure_options_in_poll!(poll_id, option_ids)
    ensure_not_submitted!(poll_id, grant.member_id)

    _participation =
      create_or_rollback(
        Participation,
        %{poll_id: poll_id, member_id: grant.member_id},
        :record
      )

    ballot =
      create_or_rollback(
        Ballot,
        ballot_attributes(poll, grant.member_id),
        :submit
      )

    Enum.each(option_ids, fn option_id ->
      create_or_rollback(Selection, %{ballot_id: ballot.id, option_id: option_id}, :select)
    end)

    ballot
  end

  defp fetch_grant!(poll_id, token) do
    case AccessGrant.resolve(poll_id, token) do
      {:ok, grant} -> grant
      {:error, _error} -> Polly.Repo.rollback(:invalid_grant)
    end
  end

  defp fetch_open_poll!(poll_id) do
    case Ash.get(Poll, poll_id, authorize?: false) do
      {:ok, %Poll{status: :open} = poll} -> poll
      _other -> Polly.Repo.rollback(:poll_not_open)
    end
  end

  defp ensure_eligible!(poll_id, member_id) do
    Eligibility
    |> Ash.Query.filter(poll_id == ^poll_id and member_id == ^member_id)
    |> Ash.exists?(authorize?: false)
    |> case do
      true -> :ok
      _other -> Polly.Repo.rollback(:member_not_eligible)
    end
  end

  defp ensure_distinct_options!(option_ids) do
    if length(option_ids) == length(Enum.uniq(option_ids)) do
      :ok
    else
      Polly.Repo.rollback(:duplicate_options)
    end
  end

  defp ensure_selection_count!(poll, option_ids) do
    count = length(option_ids)

    cond do
      count < poll.minimum_selections -> Polly.Repo.rollback(:too_few_selections)
      count > poll.maximum_selections -> Polly.Repo.rollback(:too_many_selections)
      true -> :ok
    end
  end

  defp ensure_options_in_poll!(poll_id, option_ids) do
    matching_ids =
      Option
      |> Ash.Query.filter(id in ^option_ids and poll_id == ^poll_id and active == true)
      |> Ash.Query.select([:id])
      |> Ash.read!(authorize?: false)
      |> Enum.map(& &1.id)
      |> MapSet.new()

    if matching_ids == MapSet.new(option_ids) do
      :ok
    else
      Polly.Repo.rollback(:option_not_in_poll)
    end
  end

  defp ensure_not_submitted!(poll_id, member_id) do
    Participation
    |> Ash.Query.filter(poll_id == ^poll_id and member_id == ^member_id)
    |> Ash.exists?(authorize?: false)
    |> case do
      false -> :ok
      _other -> Polly.Repo.rollback(:already_submitted)
    end
  end

  defp ballot_attributes(%Poll{privacy_mode: :identified} = poll, member_id) do
    %{poll_id: poll.id, member_id: member_id, privacy_mode: :identified}
  end

  defp ballot_attributes(%Poll{privacy_mode: :anonymous} = poll, _member_id) do
    %{poll_id: poll.id, privacy_mode: :anonymous}
  end

  defp create_or_rollback(resource, attributes, action) do
    case Ash.create(resource, attributes, action: action, authorize?: false) do
      {:ok, record} -> record
      {:error, error} -> Polly.Repo.rollback(error)
    end
  end

  defp normalize_error(%Ash.Error.Invalid{} = error) do
    if Exception.message(error) =~ "has already been taken" do
      :already_submitted
    else
      error
    end
  end

  defp normalize_error(reason), do: reason
end
