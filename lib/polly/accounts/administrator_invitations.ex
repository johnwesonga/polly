defmodule Polly.Accounts.AdministratorInvitations do
  @moduledoc "Owner boundary for creating and accepting administrator invitations."

  import Ecto.Query, only: [from: 2]

  alias Polly.Accounts.{
    AdministratorInvitation,
    AdministratorInvitationToken,
    AdministratorInvitationWorker,
    Authorization,
    User
  }

  require Ash.Query

  def invite(email, role, %User{} = actor) do
    with :ok <- Authorization.authorize(actor, :manage_administrators),
         {:ok, email} <- normalize_email(email),
         {:ok, role} <- cast_role(role) do
      transaction(fn -> create_invitation(email, role, actor) end)
    end
  end

  def invite(_email, _role, _actor), do: {:error, :unauthorized}

  def accept(id, token, password, confirmation) do
    cond do
      not is_binary(password) or String.length(password) < 8 -> {:error, :invalid_password}
      password != confirmation -> {:error, :invalid_password}
      true -> transaction(fn -> accept_invitation(id, token, password) end)
    end
  end

  def verify(id, token) do
    with {:ok, invitation} <- Ash.get(AdministratorInvitation, id, authorize?: false),
         :pending <- invitation.status,
         true <- DateTime.after?(invitation.expires_at, DateTime.utc_now()),
         true <- AdministratorInvitationToken.valid?(invitation, token) do
      {:ok, invitation}
    else
      _ -> {:error, :invalid_invitation}
    end
  end

  defp create_invitation(email, role, actor) do
    lock_users(actor.id)

    if user_exists?(email), do: rollback(:existing_user)
    if pending_exists?(email), do: rollback(:pending_invitation)

    invitation =
      Ash.create!(
        AdministratorInvitation,
        %{
          email: email,
          role: role,
          invited_by_id: actor.id,
          expires_at: DateTime.add(now(), 7, :day)
        },
        action: :invite,
        authorize?: false
      )

    %{invitation_id: invitation.id}
    |> AdministratorInvitationWorker.new()
    |> Oban.insert!()

    Polly.Audit.append!(%{
      action: "administrator.invited",
      actor: actor,
      target: %{type: "administrator_invitation", id: invitation.id, label: email},
      metadata: %{role: to_string(role)}
    })

    invitation
  end

  defp accept_invitation(id, token, password) do
    with {:ok, _invitation} <- verify(id, token) do
      Polly.Repo.query!(
        "UPDATE administrator_invitations SET updated_at = updated_at WHERE id = ?",
        [id]
      )

      invitation = Ash.get!(AdministratorInvitation, id, authorize?: false)

      unless invitation.status == :pending and
               DateTime.after?(invitation.expires_at, DateTime.utc_now()) and
               AdministratorInvitationToken.valid?(invitation, token),
             do: rollback(:invalid_invitation)

      if user_exists?(to_string(invitation.email)), do: rollback(:existing_user)

      case Ash.create(
             User,
             %{
               email: to_string(invitation.email),
               role: invitation.role,
               hashed_password: Bcrypt.hash_pwd_salt(password)
             },
             action: :accept_administrator_invitation,
             authorize?: false
           ) do
        {:ok, user} ->
          user = confirm_user!(user)

          Ash.update!(invitation, %{accepted_user_id: user.id, accepted_at: now()},
            action: :accept,
            authorize?: false
          )

          Polly.Audit.append!(%{
            action: "administrator.invitation_accepted",
            actor: user,
            target: %{type: "administrator", id: user.id, label: to_string(user.email)},
            metadata: %{role: to_string(user.role), invitation_id: invitation.id},
            source: "public_setup"
          })

          user

        {:error, error} ->
          rollback(error)
      end
    else
      _ -> rollback(:invalid_invitation)
    end
  end

  defp confirm_user!(user) do
    confirmed_at = now()

    Polly.Repo.query!("UPDATE users SET confirmed_at = ?, updated_at = ? WHERE id = ?", [
      confirmed_at,
      confirmed_at,
      user.id
    ])

    Ash.get!(User, user.id, authorize?: false)
  end

  defp user_exists?(email) do
    Polly.Repo.exists?(
      from user in "users", where: fragment("lower(?)", user.email) == ^String.downcase(email)
    )
  end

  defp pending_exists?(email) do
    Polly.Repo.exists?(
      from invitation in "administrator_invitations",
        where:
          invitation.status == "pending" and
            fragment("lower(?)", invitation.email) == ^String.downcase(email) and
            invitation.expires_at > ^now()
    )
  end

  defp lock_users(id),
    do: Polly.Repo.query!("UPDATE users SET updated_at = updated_at WHERE id = ?", [id])

  defp normalize_email(email) when is_binary(email) do
    email = email |> String.trim() |> String.downcase()

    if Regex.match?(~r/^[^\s@]+@[^\s@]+\.[^\s@]+$/, email),
      do: {:ok, email},
      else: {:error, :invalid_email}
  end

  defp normalize_email(_), do: {:error, :invalid_email}

  defp cast_role(role) do
    case Ash.Type.cast_input(User.Role, role) do
      {:ok, role} -> {:ok, role}
      _ -> {:error, :invalid_role}
    end
  end

  defp transaction(fun) do
    case Polly.Repo.transaction(fun) do
      {:ok, result} -> {:ok, result}
      {:error, reason} -> {:error, reason}
    end
  rescue
    error -> {:error, error}
  end

  defp rollback(reason), do: Polly.Repo.rollback(reason)
  defp now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)
end
