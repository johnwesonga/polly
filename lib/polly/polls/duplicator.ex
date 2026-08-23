defmodule Polly.Polls.Duplicator do
  @moduledoc "Creates an independent draft containing only a source poll's details."

  require Ash.Query

  alias Polly.Polls.{Poll, Slug}

  @title_limit 160
  @max_slug_attempts 100

  @type result :: %{
          poll: Poll.t(),
          source_title: String.t(),
          options_copied: 0,
          members_copied: 0,
          members_skipped: 0
        }

  @spec duplicate(Poll.t() | Ecto.UUID.t(), term()) :: {:ok, result()} | {:error, term()}
  def duplicate(_source, nil), do: {:error, :actor_required}

  def duplicate(source, actor) do
    source_id = if is_struct(source, Poll), do: source.id, else: source

    with {:ok, source_poll} <- Ash.get(Poll, source_id, actor: actor) do
      case Polly.Repo.transaction(fn -> create_duplicate(source_poll, actor) end) do
        {:ok, duplicate} ->
          {:ok,
           %{
             poll: duplicate,
             source_title: source_poll.title,
             options_copied: 0,
             members_copied: 0,
             members_skipped: 0
           }}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp create_duplicate(source, actor) do
    attributes = %{
      title: copy_title(source.title),
      description: source.description,
      selection_mode: source.selection_mode
    }

    create_with_unique_slug(attributes.title, attributes, actor, 1)
  end

  defp create_with_unique_slug(_title, _attributes, _actor, attempt)
       when attempt > @max_slug_attempts do
    Polly.Repo.rollback(:slug_generation_exhausted)
  end

  defp create_with_unique_slug(title, attributes, actor, attempt) do
    slug = Slug.candidate_for_title(title, attempt)

    if slug_exists?(slug, actor) do
      create_with_unique_slug(title, attributes, actor, attempt + 1)
    else
      case Ash.create(Poll, Map.put(attributes, :slug, slug), actor: actor) do
        {:ok, duplicate} ->
          duplicate

        {:error, error} ->
          if unique_slug_error?(error) do
            create_with_unique_slug(title, attributes, actor, attempt + 1)
          else
            Polly.Repo.rollback(error)
          end
      end
    end
  end

  defp slug_exists?(slug, actor) do
    Poll
    |> Ash.Query.filter(slug == ^slug)
    |> Ash.exists?(actor: actor)
  end

  defp copy_title(title) do
    prefix = "Copy of "
    base_title = Regex.replace(~r/^(?:Copy of )+/i, title, "")

    prefix <> String.slice(base_title, 0, @title_limit - String.length(prefix))
  end

  defp unique_slug_error?(error), do: Exception.message(error) =~ "has already been taken"
end
