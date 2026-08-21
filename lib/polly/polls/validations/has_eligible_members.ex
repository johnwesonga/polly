defmodule Polly.Polls.Validations.HasEligibleMembers do
  use Ash.Resource.Validation

  alias Ash.Error.Changes.InvalidAttribute
  alias Polly.Polls.Eligibility

  @impl true
  def init(opts), do: {:ok, opts}

  @impl true
  def validate(changeset, _opts, _context) do
    eligible? =
      Eligibility
      |> Ash.Query.filter(poll_id == ^changeset.data.id)
      |> Ash.exists?(authorize?: false)

    if eligible? do
      :ok
    else
      {:error,
       InvalidAttribute.exception(
         field: :status,
         value: :open,
         message: "cannot be opened until at least one member is eligible"
       )}
    end
  end
end
