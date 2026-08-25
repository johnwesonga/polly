defmodule Polly.Audit.Changes.AppendMemberEvent do
  @moduledoc false

  use Ash.Resource.Change

  @impl true
  def change(changeset, opts, _context) do
    Ash.Changeset.after_action(changeset, fn changeset, member ->
      if get_in(changeset.context, [:audit]) == :skip do
        {:ok, member}
      else
        action = event_action(changeset, opts[:action])
        metadata = if action == "member.created", do: %{}, else: changed_fields(changeset)

        case Polly.Audit.append(%{
               action: action,
               actor: get_in(changeset.context, [:private, :actor]),
               target: %{type: "member", id: member.id, label: member.name},
               metadata: metadata
             }) do
          {:ok, _event} -> {:ok, member}
          {:error, error} -> {:error, error}
        end
      end
    end)
  end

  defp event_action(changeset, "member.updated") do
    case Map.fetch(changeset.attributes, :active) do
      {:ok, true} when changeset.data.active == false -> "member.activated"
      {:ok, false} when changeset.data.active == true -> "member.deactivated"
      _other -> "member.updated"
    end
  end

  defp event_action(_changeset, action), do: action

  defp changed_fields(changeset) do
    %{
      changed_fields:
        changeset.attributes |> Map.keys() |> Enum.map(&Atom.to_string/1) |> Enum.sort()
    }
  end
end
