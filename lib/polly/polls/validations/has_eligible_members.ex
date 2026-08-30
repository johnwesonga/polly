defmodule Polly.Polls.Validations.HasEligibleMembers do
  @moduledoc """
  Prevents a poll from opening without an electorate.

  The validation checks for at least one eligibility record belonging to the
  poll and reports the failure against its `status` transition to `:open`.
  """

  use Ash.Resource.Validation

  alias Ash.Error.Changes.InvalidAttribute
  @impl true
  def init(opts), do: {:ok, opts}

  @impl true
  def validate(changeset, _opts, _context) do
    if Polly.Polls.Readiness.has_eligible_members?(changeset.data.id) do
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
