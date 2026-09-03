defmodule Polly.Polls.Validations.BallotPrivacyIsValid do
  @moduledoc """
  Keeps a ballot's member identity consistent with its privacy snapshot.

  Identified ballots require a member, while anonymous ballots forbid one.
  """

  use Ash.Resource.Validation

  alias Ash.Error.Changes.InvalidAttribute

  @impl true
  def init(opts), do: {:ok, opts}

  @impl true
  def validate(changeset, _opts, _context) do
    privacy_mode = Ash.Changeset.get_attribute(changeset, :privacy_mode)
    member_id = Ash.Changeset.get_attribute(changeset, :member_id)

    case {privacy_mode, member_id} do
      {:identified, nil} ->
        invalid("is required for an identified ballot")

      {:anonymous, member_id} when not is_nil(member_id) ->
        invalid("must be absent from an anonymous ballot")

      _valid ->
        :ok
    end
  end

  defp invalid(message) do
    {:error,
     InvalidAttribute.exception(
       field: :member_id,
       message: message
     )}
  end
end
