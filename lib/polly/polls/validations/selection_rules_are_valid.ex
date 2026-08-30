defmodule Polly.Polls.Validations.SelectionRulesAreValid do
  @moduledoc """
  Enforces a consistent selection mode and inclusive selection-count range.

  Single-choice polls always use `1..1`. Multiple-choice polls may use any
  positive range whose minimum does not exceed its maximum.
  """

  use Ash.Resource.Validation

  alias Ash.Error.Changes.InvalidAttribute

  @impl true
  def init(opts), do: {:ok, opts}

  @impl true
  def validate(changeset, _opts, _context) do
    mode = Ash.Changeset.get_attribute(changeset, :selection_mode)
    minimum = Ash.Changeset.get_attribute(changeset, :minimum_selections)
    maximum = Ash.Changeset.get_attribute(changeset, :maximum_selections)

    cond do
      mode == :single and (minimum != 1 or maximum != 1) ->
        invalid(
          :selection_mode,
          mode,
          "single-choice polls must require exactly one selection"
        )

      is_integer(minimum) and is_integer(maximum) and minimum > maximum ->
        invalid(
          :maximum_selections,
          maximum,
          "must be greater than or equal to the minimum selections"
        )

      true ->
        :ok
    end
  end

  defp invalid(field, value, message) do
    {:error, InvalidAttribute.exception(field: field, value: value, message: message)}
  end
end
