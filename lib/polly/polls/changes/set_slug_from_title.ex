defmodule Polly.Polls.Changes.SetSlugFromTitle do
  @moduledoc false

  use Ash.Resource.Change

  alias Ash.Error.Changes.InvalidAttribute
  alias Polly.Polls.Slug

  @impl true
  def change(changeset, _opts, _context) do
    if Ash.Changeset.changing_attribute?(changeset, :title) do
      title = Ash.Changeset.get_attribute(changeset, :title)
      poll_id = changeset.data.id

      case Slug.unique_from_title(title || "", poll_id) do
        nil ->
          Ash.Changeset.add_error(
            changeset,
            InvalidAttribute.exception(
              field: :slug,
              value: nil,
              message: "could not generate a unique slug"
            )
          )

        slug ->
          Ash.Changeset.force_change_attribute(changeset, :slug, slug)
      end
    else
      changeset
    end
  end
end
