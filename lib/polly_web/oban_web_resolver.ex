defmodule PollyWeb.ObanWebResolver do
  @moduledoc "Restricts the operational job dashboard to authenticated, read-only access."

  @behaviour Oban.Web.Resolver

  @impl true
  def resolve_user(conn), do: conn.assigns[:current_user]

  @impl true
  def resolve_access(nil), do: {:forbidden, "/sign-in"}

  def resolve_access(administrator) do
    if Polly.Accounts.Authorization.allowed?(administrator, :view_jobs) do
      :read_only
    else
      {:forbidden, "/admin"}
    end
  end
end
