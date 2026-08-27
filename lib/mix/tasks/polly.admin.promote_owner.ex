defmodule Mix.Tasks.Polly.Admin.PromoteOwner do
  use Mix.Task

  @shortdoc "Promotes an existing active, confirmed Polly user to owner"

  @moduledoc """
  Emergency owner recovery command for a trusted release shell.

      mix polly.admin.promote_owner administrator@example.com

  The command refuses unconfirmed or disabled accounts. It never creates an
  account, changes a password, or prints authentication credentials.
  """

  require Ash.Query

  @impl Mix.Task
  def run([email]) do
    Mix.Task.run("app.start")

    user =
      Polly.Accounts.User
      |> Ash.Query.filter(email == ^email)
      |> Ash.read_one!(authorize?: false)

    if is_nil(user) do
      Mix.raise("No administrator exists for #{email}")
    end

    case Ash.update(user, %{}, action: :recover_owner, authorize?: false) do
      {:ok, owner} ->
        Mix.shell().info("Promoted administrator #{owner.email} (#{owner.id}) to owner")

      {:error, error} ->
        message = error |> Ash.Error.to_error_class() |> Exception.message()
        Mix.raise("Could not promote administrator: #{message}")
    end
  end

  def run(_args), do: Mix.raise("usage: mix polly.admin.promote_owner EMAIL")
end
