defmodule PollyWeb.SessionSafetyTest do
  use PollyWeb.ConnCase, async: false

  alias Polly.Accounts.{Administrators, User}

  test "a disabled account is rejected on its next controller request", %{conn: conn} do
    {conn, administrator} =
      register_and_log_in_administrator(conn, %{role: :administrator})

    owner = create_user!(:owner)
    assert {:ok, _disabled} = Administrators.disable(administrator, owner)

    conn = get(conn, ~p"/admin/polls/#{Ecto.UUID.generate()}/results.csv")

    assert redirected_to(conn) == ~p"/sign-in"
    assert Phoenix.Flash.get(conn.assigns.flash, :error) == "Sign in to continue"
  end

  test "an already-connected LiveView rejects the next event after deactivation", %{conn: conn} do
    target = create_user!(:owner)
    actor = create_user!(:owner)

    conn =
      conn
      |> init_test_session(%{})
      |> AshAuthentication.Plug.Helpers.store_in_session(target)

    {:ok, view, _html} = live(conn, ~p"/admin/polls")
    assert {:ok, _disabled} = Administrators.disable(target, actor)

    assert {:error, {:redirect, %{to: "/sign-in"}}} = render_click(view, "next-page", %{})
  end

  test "successful authentication records the sign-in timestamp", %{conn: conn} do
    user = create_user!(:owner)
    user = Ash.Resource.put_metadata(user, :token, user.__metadata__.token)

    conn =
      conn
      |> init_test_session(%{})
      |> Phoenix.Controller.fetch_flash([])

    conn =
      PollyWeb.AuthController.success(conn, {:password, :sign_in}, user, user.__metadata__.token)

    reloaded = Ash.get!(User, user.id, authorize?: false)

    assert redirected_to(conn) == ~p"/admin"
    assert %DateTime{} = reloaded.last_signed_in_at
  end

  defp create_user!(role) do
    Ash.create!(
      User,
      %{
        email: "session-#{System.unique_integer([:positive])}@example.com",
        password: "secure-password",
        password_confirmation: "secure-password",
        role: role
      },
      action: :register_with_password,
      authorize?: false
    )
  end
end
