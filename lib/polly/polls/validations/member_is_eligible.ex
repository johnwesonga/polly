defmodule Polly.Polls.Validations.MemberIsEligible do
  use Ash.Resource.Validation

  alias Ash.Error.Changes.InvalidAttribute
  alias Polly.Polls.Eligibility

  @impl true
  def init(opts), do: {:ok, opts}

  @impl true
  def validate(changeset, _opts, _context) do
    poll_id = Ash.Changeset.get_attribute(changeset, :poll_id)
    member_id = Ash.Changeset.get_attribute(changeset, :member_id)

    eligible? =
      Eligibility
      |> Ash.Query.filter(poll_id == ^poll_id and member_id == ^member_id)
      |> Ash.exists?(authorize?: false)

    if eligible? do
      :ok
    else
      {:error,
       InvalidAttribute.exception(
         field: :member_id,
         value: member_id,
         message: "is not eligible for this poll"
       )}
    end
  end
end
