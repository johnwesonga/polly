defmodule Polly.Polls.Options do
  @moduledoc "Transactional option operations that span multiple resource writes."

  alias Polly.Polls.Option

  def reorder(%Option{} = option, %Option{} = neighbor, temporary_position, actor) do
    {:ok, result} =
      Polly.Repo.transaction(fn ->
        old_position = option.position
        new_position = neighbor.position

        option = update_position!(option, temporary_position, actor)
        _neighbor = update_position!(neighbor, old_position, actor)
        option = update_position!(option, new_position, actor)

        Polly.Audit.append!(%{
          action: "poll_option.reordered",
          actor: actor,
          target: %{type: "poll_option", id: option.id, label: option.label},
          poll_id: option.poll_id,
          metadata: %{old_position: old_position, new_position: new_position}
        })

        option
      end)

    result
  end

  defp update_position!(option, position, actor) do
    Ash.update!(option, %{position: position}, actor: actor, context: %{audit: :skip})
  end
end
