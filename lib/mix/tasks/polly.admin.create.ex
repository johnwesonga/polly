defmodule Mix.Tasks.Polly.Admin.Create do
  use Mix.Task

  @shortdoc "Creates a Polly administrator"

  @moduledoc """
  Creates an administrator account outside the public web application.

      POLLY_ADMIN_PASSWORD="a secure password" mix polly.admin.create admin@example.com
      POLLY_ADMIN_PASSWORD="a secure password" mix polly.admin.create admin@example.com --role administrator

  The password must be at least eight characters. In development, confirmation
  mail is available in the local mailbox at `/dev/mailbox`. The role defaults
  to `owner`; accepted roles are owner, administrator, auditor, and operator.
  """

  @impl Mix.Task
  def run(args) do
    {options, positional, invalid} =
      OptionParser.parse(args, strict: [role: :string], aliases: [r: :role])

    {email, role} = parse_arguments!(options, positional, invalid)

    password =
      System.get_env("POLLY_ADMIN_PASSWORD") ||
        Mix.raise("POLLY_ADMIN_PASSWORD must be set")

    Mix.Task.run("app.start")

    case Ash.create(
           Polly.Accounts.User,
           %{email: email, password: password, password_confirmation: password, role: role},
           action: :register_with_password,
           authorize?: false
         ) do
      {:ok, administrator} ->
        confirmation =
          if administrator.confirmed_at, do: "confirmed", else: "confirmation required"

        Mix.shell().info("Created #{administrator.role} administrator #{email} (#{confirmation})")

      {:error, error} ->
        message = error |> Ash.Error.to_error_class() |> Exception.message()
        Mix.raise("Could not create administrator: #{message}")
    end
  end

  defp parse_arguments!(options, [email], []) do
    role = options |> Keyword.get(:role, "owner") |> parse_role!()
    {email, role}
  end

  defp parse_arguments!(_options, _positional, _invalid) do
    Mix.raise("usage: mix polly.admin.create EMAIL [--role ROLE]")
  end

  defp parse_role!(role) do
    case Ash.Type.cast_input(Polly.Accounts.User.Role, role) do
      {:ok, parsed_role} when not is_nil(parsed_role) ->
        parsed_role

      _ ->
        Mix.raise(
          "invalid role #{inspect(role)}; expected owner, administrator, auditor, or operator"
        )
    end
  end
end
