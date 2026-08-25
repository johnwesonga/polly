defmodule Polly.Polls.Duplicator do
  @moduledoc "Creates an independent draft from selected source poll configuration."

  require Ash.Query

  alias Polly.Polls.{AccessGrant, Eligibility, Option, Poll, Slug}

  @title_limit 160
  @max_slug_attempts 100

  @type result :: %{
          poll: Poll.t(),
          source_title: String.t(),
          options_copied: non_neg_integer(),
          members_copied: non_neg_integer(),
          members_skipped: non_neg_integer()
        }

  @spec duplicate(Poll.t() | Ecto.UUID.t(), term()) :: {:ok, result()} | {:error, term()}
  def duplicate(source, actor), do: duplicate(source, %{}, actor)

  @spec duplicate(Poll.t() | Ecto.UUID.t(), map(), term()) ::
          {:ok, result()} | {:error, term()}
  def duplicate(_source, _options, nil), do: {:error, :actor_required}

  def duplicate(source, options, actor) do
    source_id = if is_struct(source, Poll), do: source.id, else: source

    case Polly.Repo.transaction(fn -> duplicate_in_transaction(source_id, options, actor) end) do
      {:ok, result} -> {:ok, result}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec preview(Poll.t() | Ecto.UUID.t(), term()) :: {:ok, map()} | {:error, term()}
  def preview(_source, nil), do: {:error, :actor_required}

  def preview(source, actor) do
    source_id = if is_struct(source, Poll), do: source.id, else: source

    with {:ok, source_poll} <- Ash.get(Poll, source_id, actor: actor) do
      {active_eligibilities, skipped_eligibilities} = eligibility_snapshot(source_poll.id, actor)
      duplicate_title = copy_title(source_poll.title)

      {:ok,
       %{
         source: source_poll,
         proposed_title: duplicate_title,
         proposed_slug: Slug.unique_from_title(duplicate_title),
         active_option_count: length(active_options(source_poll.id, actor)),
         active_member_count: length(active_eligibilities),
         skipped_member_count: length(skipped_eligibilities)
       }}
    end
  end

  defp duplicate_in_transaction(source_id, options, actor) do
    source = get_source_or_rollback(source_id, actor)
    duplicate = create_duplicate(source, actor)

    options_copied =
      if Map.get(options, :copy_options?, false) do
        copy_options(source.id, duplicate.id, actor)
      else
        0
      end

    {members_copied, members_skipped} =
      if Map.get(options, :copy_electorate?, false) do
        copy_electorate(source.id, duplicate.id, actor)
      else
        {0, 0}
      end

    result = %{
      poll: duplicate,
      source_title: source.title,
      options_copied: options_copied,
      members_copied: members_copied,
      members_skipped: members_skipped
    }

    Polly.Audit.append!(%{
      action: "poll.duplicated",
      actor: actor,
      target: %{type: "poll", id: duplicate.id, label: duplicate.title},
      poll_id: duplicate.id,
      metadata: %{
        source_poll_id: source.id,
        source_poll_label: source.title,
        options_copied: options_copied,
        members_copied: members_copied,
        members_skipped: members_skipped
      }
    })

    result
  end

  defp get_source_or_rollback(source_id, actor) do
    case Ash.get(Poll, source_id, actor: actor) do
      {:ok, source} -> source
      {:error, error} -> Polly.Repo.rollback(error)
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
      case Ash.create(Poll, Map.put(attributes, :slug, slug),
             actor: actor,
             context: %{audit: :skip}
           ) do
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

  defp copy_options(source_id, duplicate_id, actor) do
    options = active_options(source_id, actor)

    Enum.each(options, fn option ->
      create_or_rollback(
        Option,
        %{poll_id: duplicate_id, label: option.label, position: option.position},
        actor
      )
    end)

    length(options)
  end

  defp active_options(poll_id, actor) do
    Option
    |> Ash.Query.filter(poll_id == ^poll_id and active == true)
    |> Ash.Query.sort(position: :asc)
    |> Ash.read!(actor: actor)
  end

  defp copy_electorate(source_id, duplicate_id, actor) do
    {active_eligibilities, skipped_eligibilities} = eligibility_snapshot(source_id, actor)

    Enum.each(active_eligibilities, fn eligibility ->
      create_or_rollback(
        Eligibility,
        %{poll_id: duplicate_id, member_id: eligibility.member_id},
        actor
      )

      create_or_rollback(
        AccessGrant,
        %{poll_id: duplicate_id, member_id: eligibility.member_id},
        actor
      )
    end)

    {length(active_eligibilities), length(skipped_eligibilities)}
  end

  defp eligibility_snapshot(poll_id, actor) do
    poll_id
    |> then(fn id ->
      Eligibility
      |> Ash.Query.filter(poll_id == ^id)
      |> Ash.Query.load(:member)
      |> Ash.read!(actor: actor)
    end)
    |> Enum.split_with(& &1.member.active)
  end

  defp create_or_rollback(resource, attributes, actor) do
    case Ash.create(resource, attributes, actor: actor) do
      {:ok, record} -> record
      {:error, error} -> Polly.Repo.rollback(error)
    end
  end

  defp copy_title(title) do
    prefix = "Copy of "
    base_title = Regex.replace(~r/^(?:Copy of )+/i, title, "")

    prefix <> String.slice(base_title, 0, @title_limit - String.length(prefix))
  end

  defp unique_slug_error?(error), do: Exception.message(error) =~ "has already been taken"
end
