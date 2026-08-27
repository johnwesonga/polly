defmodule PollyWeb.ConnCase do
  @moduledoc """
  This module defines the test case to be used by
  tests that require setting up a connection.

  Such tests rely on `Phoenix.ConnTest` and also
  import other functionality to make it easier
  to build common data structures and query the data layer.

  Finally, if the test case interacts with the database,
  we enable the SQL sandbox, so changes done to the database
  are reverted at the end of every test. If you are using
  PostgreSQL, you can even run database tests asynchronously
  by setting `use PollyWeb.ConnCase, async: true`, although
  this option is not recommended for other databases.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      # The default endpoint for testing
      @endpoint PollyWeb.Endpoint

      use PollyWeb, :verified_routes

      # Import conveniences for testing with connections
      import Plug.Conn
      import Phoenix.ConnTest
      import Phoenix.LiveViewTest
      import PollyWeb.ConnCase
    end
  end

  setup tags do
    Polly.DataCase.setup_sandbox(tags)
    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end

  def register_and_log_in_administrator(conn, attributes \\ %{}) do
    email = Map.get(attributes, :email, "admin-#{System.unique_integer([:positive])}@example.com")
    password = Map.get(attributes, :password, "secure-password")

    administrator =
      Ash.create!(
        Polly.Accounts.User,
        %{
          email: email,
          password: password,
          password_confirmation: password,
          role: Map.get(attributes, :role, :administrator)
        },
        action: :register_with_password,
        authorize?: false
      )

    conn =
      conn
      |> Plug.Test.init_test_session(%{})
      |> AshAuthentication.Plug.Helpers.store_in_session(administrator)

    {conn, administrator}
  end
end
