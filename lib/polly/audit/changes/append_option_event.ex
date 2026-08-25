defmodule Polly.Audit.Changes.AppendOptionEvent do
  @moduledoc false

  use Ash.Resource.Change

  @impl true
  def change(changeset, opts, _context) do
    Ash.Changeset.after_action(changeset, fn changeset, option ->
      if get_in(changeset.context, [:audit]) == :skip do
        {:ok, option}
      else
        metadata = metadata(changeset, option, opts[:action])

        case Polly.Audit.append(%{
               action: opts[:action],
               actor: get_in(changeset.context, [:private, :actor]),
               target: %{type: "poll_option", id: option.id, label: option.label},
               poll_id: option.poll_id,
               metadata: metadata
             }) do
          {:ok, _event} -> {:ok, option}
          {:error, error} -> {:error, error}
        end
      end
    end)
  end

  defp metadata(_changeset, option, "poll_option.created"), do: %{position: option.position}
  defp metadata(_changeset, option, "poll_option.deleted"), do: %{position: option.position}

  defp metadata(changeset, _option, "poll_option.updated") do
    %{
      changed_fields:
        changeset.attributes |> Map.keys() |> Enum.map(&Atom.to_string/1) |> Enum.sort()
    }
  end
end
