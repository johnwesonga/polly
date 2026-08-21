defmodule Polly.Polls.Validations.PollIsDraft do
  use Ash.Resource.Validation

  alias Ash.Error.Changes.InvalidAttribute
  alias Polly.Polls.Poll

  @impl true
  def init(opts), do: {:ok, opts}

  @impl true
  def validate(changeset, _opts, _context) do
    poll_id = Ash.Changeset.get_attribute(changeset, :poll_id)

    case Ash.get(Poll, poll_id, authorize?: false) do
      {:ok, %{status: :draft}} ->
        :ok

      {:ok, _poll} ->
        {:error,
         InvalidAttribute.exception(
           field: :poll_id,
           value: poll_id,
           message: "belongs to a poll whose options are frozen"
         )}

      _ ->
        {:error,
         InvalidAttribute.exception(
           field: :poll_id,
           value: poll_id,
           message: "does not identify an existing poll"
         )}
    end
  end
end
