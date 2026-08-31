defmodule Polly.Audit do
  @moduledoc "Internal append boundary and event catalog for administrator audit history."

  use Ash.Domain,
    otp_app: :polly

  import Ecto.Query, only: [from: 2]

  alias Polly.Accounts.User
  alias Polly.Audit.Event

  @definitions %{
    "member.created" => [],
    "member.updated" => [:changed_fields],
    "member.activated" => [:changed_fields],
    "member.deactivated" => [:changed_fields],
    "member_import.completed" => [:created_count, :skipped_count],
    "administrator.enabled" => [],
    "administrator.disabled" => [],
    "administrator.role_changed" => [:old_role, :new_role],
    "administrator.invited" => [:role],
    "administrator.invitation_resent" => [],
    "administrator.invitation_renewed" => [:replaced_invitation_id, :role],
    "administrator.invitation_revoked" => [],
    "administrator.invitation_accepted" => [:role, :invitation_id],
    "poll.created" => [],
    "poll.updated" => [:changed_fields],
    "poll.duplicated" => [
      :source_poll_id,
      :source_poll_label,
      :options_copied,
      :members_copied,
      :members_skipped
    ],
    "poll.opened" => [:old_status, :new_status],
    "poll.closed" => [:old_status, :new_status],
    "poll.results_published" => [],
    "poll.results_made_public" => [:old_visibility, :new_visibility],
    "poll.results_made_credentialed" => [:old_visibility, :new_visibility],
    "poll.results_exported" => [
      :poll_status,
      :result_state,
      :option_count,
      :submitted_count,
      :eligible_count,
      :provisional
    ],
    "poll_option.created" => [:position],
    "poll_option.updated" => [:changed_fields],
    "poll_option.reordered" => [:old_position, :new_position],
    "poll_option.deleted" => [:position],
    "poll_electorate.member_added" => [:member_id],
    "poll_electorate.member_removed" => [:member_id],
    "poll_access_grant.issued" => [:member_id, :grant_id],
    "poll_access_grant.revoked" => [:member_id, :grant_id],
    "poll_access_grant.reissued" => [:member_id, :old_grant_id, :new_grant_id],
    "poll.invitations_enqueued" => [:queued_count, :skipped_count, :request_kind]
  }

  @forbidden_fragments ~w(token password secret url csv ballot selection email)
  @max_metadata_bytes 16_384

  resources do
    resource Polly.Audit.Event
  end

  def actions, do: Map.keys(@definitions)

  def actor_options(%User{}) do
    Polly.Repo.all(
      from event in "audit_events",
        distinct: true,
        order_by: [asc: event.actor_label],
        select: {event.actor_label, event.actor_id}
    )
  end

  def append(attributes) when is_map(attributes) do
    started_at = System.monotonic_time()
    result = do_append(attributes)

    :telemetry.execute(
      [:polly, :audit, :append],
      %{duration: System.monotonic_time() - started_at, count: 1},
      %{
        action: Map.get(attributes, :action),
        status: if(match?({:ok, _event}, result), do: :ok, else: :error)
      }
    )

    result
  end

  defp do_append(attributes) do
    with %User{} = actor <- Map.get(attributes, :actor),
         action when is_binary(action) <- Map.get(attributes, :action),
         {:ok, allowed_keys} <- fetch_definition(action),
         metadata when is_map(metadata) <- Map.get(attributes, :metadata, %{}),
         :ok <- validate_metadata(metadata, allowed_keys) do
      target = Map.fetch!(attributes, :target)

      Event
      |> Ash.Changeset.for_create(
        :append,
        %{
          operation_id: Map.get(attributes, :operation_id, Ash.UUID.generate()),
          action: action,
          actor_id: actor.id,
          actor_label: to_string(actor.email),
          target_type: Map.fetch!(target, :type),
          target_id: Map.get(target, :id),
          target_label: Map.fetch!(target, :label),
          poll_id: Map.get(attributes, :poll_id),
          metadata: stringify_keys(metadata),
          source: Map.get(attributes, :source, "admin_ui"),
          request_id: Map.get(attributes, :request_id),
          occurred_at: DateTime.utc_now()
        },
        actor: actor
      )
      |> Ash.create()
    else
      nil -> {:error, :actor_required}
      {:error, reason} -> {:error, reason}
      _invalid -> {:error, :invalid_event}
    end
  end

  def append!(attributes) do
    case append(attributes) do
      {:ok, event} -> event
      {:error, reason} -> raise "audit append failed: #{inspect(reason)}"
    end
  end

  def humanize(%Event{} = event) do
    case event.action do
      "poll.created" ->
        "created poll “#{event.target_label}”"

      "poll.updated" ->
        "updated poll “#{event.target_label}”"

      "poll.duplicated" ->
        "duplicated a poll as “#{event.target_label}”"

      "poll.opened" ->
        "opened “#{event.target_label}”"

      "poll.closed" ->
        "closed “#{event.target_label}”"

      "poll.results_published" ->
        "published results for “#{event.target_label}”"

      "poll.results_made_public" ->
        "made results public for “#{event.target_label}”"

      "poll.results_made_credentialed" ->
        "restricted results to voting links for “#{event.target_label}”"

      "poll.results_exported" ->
        "exported results for “#{event.target_label}”"

      "member.created" ->
        "created member “#{event.target_label}”"

      "member.updated" ->
        "updated member “#{event.target_label}”"

      "member.activated" ->
        "activated member “#{event.target_label}”"

      "member.deactivated" ->
        "deactivated member “#{event.target_label}”"

      "member_import.completed" ->
        "completed a member import"

      "administrator.enabled" ->
        "enabled administrator “#{event.target_label}”"

      "administrator.disabled" ->
        "disabled administrator “#{event.target_label}”"

      "administrator.role_changed" ->
        "changed the role for “#{event.target_label}”"

      "administrator.invited" ->
        "invited administrator “#{event.target_label}”"

      "administrator.invitation_resent" ->
        "resent an invitation to “#{event.target_label}”"

      "administrator.invitation_renewed" ->
        "renewed an invitation for “#{event.target_label}”"

      "administrator.invitation_revoked" ->
        "revoked an invitation for “#{event.target_label}”"

      "administrator.invitation_accepted" ->
        "accepted an administrator invitation for “#{event.target_label}”"

      "poll_option.created" ->
        "created option “#{event.target_label}”"

      "poll_option.updated" ->
        "updated option “#{event.target_label}”"

      "poll_option.reordered" ->
        "reordered option “#{event.target_label}”"

      "poll_option.deleted" ->
        "deleted option “#{event.target_label}”"

      "poll_electorate.member_added" ->
        "added “#{event.target_label}” to an electorate"

      "poll_electorate.member_removed" ->
        "removed “#{event.target_label}” from an electorate"

      "poll_access_grant.issued" ->
        "issued access for “#{event.target_label}”"

      "poll_access_grant.revoked" ->
        "revoked access for “#{event.target_label}”"

      "poll_access_grant.reissued" ->
        "reissued access for “#{event.target_label}”"

      "poll.invitations_enqueued" ->
        "queued email invitations for “#{event.target_label}”"

      _unknown ->
        event.action <> " on “#{event.target_label}”"
    end
  end

  defp fetch_definition(action) do
    case Map.fetch(@definitions, action) do
      {:ok, keys} -> {:ok, keys}
      :error -> {:error, :unknown_action}
    end
  end

  defp validate_metadata(metadata, allowed_keys) do
    keys = Map.keys(metadata)

    cond do
      Enum.any?(keys, &(not is_atom(&1))) ->
        {:error, :invalid_metadata_keys}

      Enum.any?(keys, &(&1 not in allowed_keys)) ->
        {:error, :metadata_not_allowed}

      Enum.any?(keys, &forbidden_key?/1) ->
        {:error, :sensitive_metadata}

      not json_compatible?(metadata) ->
        {:error, :invalid_metadata}

      byte_size(Jason.encode!(metadata)) > @max_metadata_bytes ->
        {:error, :metadata_too_large}

      true ->
        :ok
    end
  end

  defp forbidden_key?(key) do
    key = Atom.to_string(key)
    Enum.any?(@forbidden_fragments, &String.contains?(key, &1))
  end

  defp json_compatible?(value) when is_binary(value) or is_boolean(value) or is_number(value),
    do: true

  defp json_compatible?(nil), do: true
  defp json_compatible?(value) when is_list(value), do: Enum.all?(value, &json_compatible?/1)

  defp json_compatible?(value) when is_map(value),
    do: Enum.all?(value, fn {key, item} -> is_atom(key) and json_compatible?(item) end)

  defp json_compatible?(_value), do: false

  defp stringify_keys(metadata),
    do: Map.new(metadata, fn {key, value} -> {Atom.to_string(key), value} end)
end
