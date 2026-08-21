defmodule Mix.Tasks.Polly.Admin.Create do
  use Mix.Task

  @shortdoc "Creates a Polly administrator"

  @moduledoc """
  Creates an administrator account outside the public web application.

      POLLY_ADMIN_PASSWORD="a secure password" mix polly.admin.create admin@example.com

  The password must be at least eight characters. In development, confirmation
  mail is available in the local mailbox at `/dev/mailbox`.
  """

  @impl Mix.Task
  def run([email]) do
    password =
      System.get_env("POLLY_ADMIN_PASSWORD") ||
        Mix.raise("POLLY_ADMIN_PASSWORD must be set")

    Mix.Task.run("app.start")

    case Ash.create(
           Polly.Accounts.User,
           %{email: email, password: password, password_confirmation: password},
           action: :register_with_password,
           authorize?: false
         ) do
      {:ok, _administrator} ->
        Mix.shell().info("Created administrator #{email}")

      {:error, error} ->
        Mix.raise("Could not create administrator: #{Ash.Error.to_error_class(error)}")
    end
  end

  def run(_args) do
    Mix.raise("usage: mix polly.admin.create EMAIL")
  end
end
