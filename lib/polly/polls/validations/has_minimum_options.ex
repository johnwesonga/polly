defmodule Polly.Polls.Validations.HasMinimumOptions do
  @moduledoc """
  Prevents a poll from opening without enough active choices.

  A poll must have at least two active options before its status may transition
  to `:open`, ensuring that voters are presented with a meaningful choice.
  """

  use Ash.Resource.Validation

  alias Ash.Error.Changes.InvalidAttribute
  @impl true
  def init(opts), do: {:ok, opts}

  @impl true
  def validate(changeset, _opts, _context) do
    if Polly.Polls.Readiness.has_minimum_options?(changeset.data.id) do
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
