defmodule PollyWeb.AuthController do
  use PollyWeb, :controller
  use AshAuthentication.Phoenix.Controller

  alias Polly.Accounts.{Administrators, User}

  def success(conn, activity, %User{status: :active} = user, token) do
    return_to = get_session(conn, :return_to) || ~p"/admin"
    {:ok, user} = Administrators.record_sign_in(user)
    user = Ash.Resource.put_metadata(user, :token, token)

    message =
      case activity do
        {:confirm_new_user, :confirm} -> "Your email address has now been confirmed"
        {:password, :reset} -> "Your password has successfully been reset"
        _ -> "You are now signed in"
      end

    conn
    |> delete_session(:return_to)
    |> store_in_session(user)
    # If your resource has a different name, update the assign name here (i.e :current_admin)
    |> assign(:current_user, user)
    |> put_flash(:info, message)
    |> redirect(to: return_to)
  end

  def success(conn, _activity, %User{}, _token) do
    conn
    |> clear_session(:polly)
    |> put_flash(:error, "This administrator account is disabled")
    |> redirect(to: ~p"/sign-in")
  end

  def failure(conn, activity, reason) do
    message =
      case {activity, reason} do
        {_,
         %AshAuthentication.Errors.AuthenticationFailed{
           caused_by: %Ash.Error.Forbidden{
             errors: [%AshAuthentication.Errors.CannotConfirmUnconfirmedUser{}]
           }
         }} ->
          """
          You have already signed in another way, but have not confirmed your account.
          You can confirm your account using the link we sent to you, or by resetting your password.
          """

        {_,
         %AshAuthentication.Errors.AuthenticationFailed{
           caused_by: %AshAuthentication.Errors.ConfirmationRequired{}
         }} ->
          """
          An account with this email already exists. We've sent a link to that
          address - confirm it to finish linking this provider to your account.
          """

        _ ->
          "Incorrect email or password"
      end

    conn
    |> put_flash(:error, message)
    |> redirect(to: ~p"/sign-in")
  end

  def sign_out(conn, _params) do
    return_to = get_session(conn, :return_to) || ~p"/sign-in"

    conn
    |> clear_session(:polly)
    |> put_flash(:info, "You are now signed out")
    |> redirect(to: return_to)
  end
end
