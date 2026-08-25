defmodule Polly.Audit.Changes.AppendPollEvent do
  @moduledoc false

  use Ash.Resource.Change

  @impl true
  def change(changeset, opts, _context) do
    Ash.Changeset.after_action(changeset, fn changeset, poll ->
      if get_in(changeset.context, [:audit]) == :skip do
        {:ok, poll}
      else
        metadata = metadata(changeset, opts[:action])

        case Polly.Audit.append(%{
               action: opts[:action],
               actor: get_in(changeset.context, [:private, :actor]),
               target: %{type: "poll", id: poll.id, label: poll.title},
               poll_id: poll.id,
               metadata: metadata
             }) do
          {:ok, _event} -> {:ok, poll}
          {:error, error} -> {:error, error}
        end
      end
    end)
  end

  defp metadata(changeset, "poll.updated") do
    %{
      changed_fields:
        changeset.attributes |> Map.keys() |> Enum.map(&Atom.to_string/1) |> Enum.sort()
    }
  end

  defp metadata(changeset, "poll.opened"),
    do: %{old_status: to_string(changeset.data.status), new_status: "open"}

  defp metadata(changeset, "poll.closed"),
    do: %{old_status: to_string(changeset.data.status), new_status: "closed"}

  defp metadata(_changeset, _action), do: %{}
end
