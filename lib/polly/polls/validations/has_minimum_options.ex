defmodule Polly.Polls.Validations.HasMinimumOptions do
  use Ash.Resource.Validation

  alias Ash.Error.Changes.InvalidAttribute
  alias Polly.Polls.Option

  @impl true
  def init(opts), do: {:ok, opts}

  @impl true
  def validate(changeset, _opts, _context) do
    poll_id = changeset.data.id

    count =
      Option
      |> Ash.Query.filter(poll_id == ^poll_id and active == true)
      |> Ash.count!(authorize?: false)

    if count >= 2 do
      :ok
    else
      {:error,
       InvalidAttribute.exception(
         field: :status,
         value: :open,
         message: "cannot be opened until it has at least two active options"
       )}
    end
  end
end
