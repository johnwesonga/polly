defmodule Polly.Polls.Ballots do
  @moduledoc "Transactional, token-authenticated ballot submission."

  require Ash.Query

  alias Polly.Polls.{AccessGrant, Ballot, Eligibility, Option, Poll, Selection}

  @type submission_error ::
          :invalid_grant
          | :poll_not_open
          | :member_not_eligible
          | :option_not_in_poll
          | :already_submitted

  @doc """
  Submits one final selection using a poll-scoped access token.

  The member is always derived from the grant. All checks and both inserts run
  in one transaction; the ballot identity also protects against racing calls.
  """
  @spec submit(Ecto.UUID.t(), String.t(), Ecto.UUID.t()) ::
          {:ok, Ballot.t()} | {:error, submission_error() | term()}
  def submit(poll_id, token, option_id) do
    case Polly.Repo.transaction(fn -> submit_in_transaction(poll_id, token, option_id) end) do
      {:ok, ballot} -> {:ok, ballot}
      {:error, reason} -> {:error, normalize_error(reason)}
    end
  end

  defp submit_in_transaction(poll_id, token, option_id) do
    grant = fetch_grant!(poll_id, token)
    ensure_poll_open!(poll_id)
    ensure_eligible!(poll_id, grant.member_id)
    ensure_option_in_poll!(poll_id, option_id)
    ensure_not_submitted!(poll_id, grant.member_id)

    ballot =
      create_or_rollback(Ballot, %{poll_id: poll_id, member_id: grant.member_id}, :submit)

    _selection =
      create_or_rollback(Selection, %{ballot_id: ballot.id, option_id: option_id}, :select)

    ballot
  end

  defp fetch_grant!(poll_id, token) do
    case AccessGrant.resolve(poll_id, token) do
      {:ok, grant} -> grant
      {:error, _error} -> Polly.Repo.rollback(:invalid_grant)
    end
  end

  defp ensure_poll_open!(poll_id) do
    case Ash.get(Poll, poll_id, authorize?: false) do
      {:ok, %Poll{status: :open}} -> :ok
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

  defp ensure_option_in_poll!(poll_id, option_id) do
    Option
    |> Ash.Query.filter(id == ^option_id and poll_id == ^poll_id and active == true)
    |> Ash.exists?(authorize?: false)
    |> case do
      true -> :ok
      _other -> Polly.Repo.rollback(:option_not_in_poll)
    end
  end

  defp ensure_not_submitted!(poll_id, member_id) do
    Ballot
    |> Ash.Query.filter(poll_id == ^poll_id and member_id == ^member_id)
    |> Ash.exists?(authorize?: false)
    |> case do
      false -> :ok
      _other -> Polly.Repo.rollback(:already_submitted)
    end
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
