defmodule Polly.Accounts.Administrators do
  @moduledoc """
  Lockout-safe lifecycle operations for Polly administrator accounts.

  These operations are the trusted boundary for phase 2. Web-facing role
  authorization is introduced in phase 3, but lifecycle mutations already
  require an active owner actor.
  """

  alias Polly.Accounts.{Token, User}

  require Ash.Query

  @type lifecycle_error ::
          :actor_required
          | :unauthorized
          | :target_not_found
          | :cannot_disable_self
          | :last_active_owner
          | Ash.Error.t()

  @spec disable(User.t(), User.t()) :: {:ok, User.t()} | {:error, lifecycle_error()}
  def disable(%User{} = target, %User{} = actor) do
    transact(actor, target, fn actor, target ->
      cond do
        actor.id == target.id ->
          rollback(:cannot_disable_self)

        target.status == :disabled ->
          target

        final_owner?(target) ->
          rollback(:last_active_owner)

        true ->
          updated =
            update!(target, %{status: :disabled, disabled_at: now()})

          revoke_sessions!(target)
          audit!("administrator.disabled", actor, target, %{})
          updated
      end
    end)
  end

  def disable(_target, _actor), do: {:error, :actor_required}

  @spec enable(User.t(), User.t()) :: {:ok, User.t()} | {:error, lifecycle_error()}
  def enable(%User{} = target, %User{} = actor) do
    transact(actor, target, fn actor, target ->
      if target.status == :active do
        target
      else
        updated = update!(target, %{status: :active, disabled_at: nil})
        audit!("administrator.enabled", actor, target, %{})
        updated
      end
    end)
  end

  def enable(_target, _actor), do: {:error, :actor_required}

  @spec change_role(User.t(), User.Role.t(), User.t()) ::
          {:ok, User.t()} | {:error, lifecycle_error()}
  def change_role(%User{} = target, role, %User{} = actor) do
    with {:ok, role} <- Ash.Type.cast_input(User.Role, role) do
      transact(actor, target, fn actor, target ->
        cond do
          target.role == role ->
            target

          target.role == :owner and role != :owner and final_owner?(target) ->
            rollback(:last_active_owner)

          true ->
            updated = update!(target, %{role: role})
            revoke_sessions!(target)

            audit!("administrator.role_changed", actor, target, %{
              old_role: to_string(target.role),
              new_role: to_string(role)
            })

            updated
        end
      end)
    else
      _ -> {:error, :invalid_role}
    end
  end

  def change_role(_target, _role, _actor), do: {:error, :actor_required}

  @doc "Records the completion of a successful interactive authentication."
  @spec record_sign_in(User.t()) :: {:ok, User.t()} | {:error, Ash.Error.t()}
  def record_sign_in(%User{status: :active} = user) do
    case Ash.update(
           user,
           %{last_signed_in_at: now()},
           action: :update_account_lifecycle,
           authorize?: false
         ) do
      {:ok, updated} -> {:ok, Ash.Resource.set_metadata(updated, user.__metadata__)}
      error -> error
    end
  end

  def record_sign_in(%User{}), do: {:error, :account_disabled}

  @doc "Reloads an active user for long-lived session checks."
  @spec fetch_active(User.t() | Ash.UUID.t()) :: {:ok, User.t()} | {:error, :inactive}
  def fetch_active(%User{id: id}), do: fetch_active(id)

  def fetch_active(id) do
    case Ash.get(User, id, authorize?: false) do
      {:ok, %User{status: :active} = user} -> {:ok, user}
      _ -> {:error, :inactive}
    end
  end

  defp transact(actor, target, operation) do
    case Polly.Repo.transaction(fn ->
           actor = reload!(actor)

           if actor.status != :active or actor.role != :owner do
             rollback(:unauthorized)
           end

           # Acquire SQLite's write lock before evaluating the final-owner
           # invariant so concurrent lifecycle requests cannot both pass it.
           Polly.Repo.query!("UPDATE users SET updated_at = updated_at WHERE id = ?", [actor.id])

           target = reload!(target)
           operation.(actor, target)
         end) do
      {:ok, result} -> {:ok, result}
      {:error, reason} -> {:error, reason}
    end
  end

  defp reload!(%User{id: id}) do
    case Ash.get(User, id, authorize?: false) do
      {:ok, user} -> user
      _ -> rollback(:target_not_found)
    end
  end

  defp final_owner?(%User{role: :owner, status: :active}) do
    %{rows: [[count]]} =
      Polly.Repo.query!("SELECT COUNT(*) FROM users WHERE role = 'owner' AND status = 'active'")

    count <= 1
  end

  defp final_owner?(_user), do: false

  defp update!(user, attributes) do
    case Ash.update(
           user,
           attributes,
           action: :update_account_lifecycle,
           authorize?: false
         ) do
      {:ok, updated} -> updated
      {:error, error} -> rollback(error)
    end
  end

  defp revoke_sessions!(user) do
    subject = AshAuthentication.user_to_subject(user)

    result =
      Token
      |> Ash.Query.filter(subject == ^subject)
      |> Ash.bulk_update(
        :revoke_all_stored_for_subject,
        %{subject: subject},
        authorize?: false,
        return_errors?: true,
        stop_on_error?: true
      )

    if result.status != :success, do: rollback({:token_revocation_failed, result.errors})
  end

  defp audit!(action, actor, target, metadata) do
    case Polly.Audit.append(%{
           action: action,
           actor: actor,
           target: %{type: "administrator", id: target.id, label: to_string(target.email)},
           metadata: metadata
         }) do
      {:ok, event} -> event
      {:error, error} -> rollback({:audit_failed, error})
    end
  end

  defp rollback(reason), do: Polly.Repo.rollback(reason)
  defp now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)
end
