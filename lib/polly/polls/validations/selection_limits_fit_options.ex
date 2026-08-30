defmodule Polly.Polls.Validations.SelectionLimitsFitOptions do
  @moduledoc """
  Prevents a poll from opening when its selection limits exceed its active
  option count.
  """

  use Ash.Resource.Validation

  alias Ash.Error.Changes.InvalidAttribute

  @impl true
  def init(opts), do: {:ok, opts}

  @impl true
  def validate(changeset, _opts, _context) do
    active_options = Polly.Polls.Readiness.active_option_count(changeset.data.id)
    minimum = Ash.Changeset.get_attribute(changeset, :minimum_selections)
    maximum = Ash.Changeset.get_attribute(changeset, :maximum_selections)

    cond do
      minimum > active_options ->
        invalid(
          :minimum_selections,
          minimum,
          "cannot exceed the #{active_options} active options"
        )

      maximum > active_options ->
        invalid(
          :maximum_selections,
          maximum,
          "cannot exceed the #{active_options} active options"
        )

      true ->
        :ok
    end
  end

  defp invalid(field, value, message) do
    {:error, InvalidAttribute.exception(field: field, value: value, message: message)}
  end
end
