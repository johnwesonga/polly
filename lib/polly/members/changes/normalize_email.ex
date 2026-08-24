defmodule Polly.Members.Changes.NormalizeEmail do
  @moduledoc "Normalizes member email addresses before persistence."

  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.before_action(changeset, fn changeset ->
      case Ash.Changeset.get_attribute(changeset, :email) do
        email when is_binary(email) ->
          normalized = email |> String.trim() |> String.downcase()
          Ash.Changeset.force_change_attribute(changeset, :email, empty_to_nil(normalized))

        _email ->
          changeset
      end
    end)
  end

  defp empty_to_nil(""), do: nil
  defp empty_to_nil(email), do: email
end
