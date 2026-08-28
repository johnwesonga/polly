defmodule Polly.Accounts.Authorization do
  @moduledoc "Central role-to-permission mapping for administrator authorization."

  alias Polly.Accounts.User

  @permissions [
    :manage_administrators,
    :manage_members,
    :manage_polls,
    :manage_electorates,
    :manage_access_grants,
    :send_invitations,
    :view_results,
    :publish_results,
    :export_results,
    :export_access_links,
    :view_audit,
    :view_jobs,
    :operate_jobs
  ]

  @role_permissions %{
    owner: @permissions -- [:operate_jobs],
    administrator: [
      :manage_members,
      :manage_polls,
      :manage_electorates,
      :manage_access_grants,
      :send_invitations,
      :view_results,
      :publish_results,
      :export_results,
      :export_access_links
    ],
    auditor: [:view_results, :export_results, :view_audit],
    operator: [:view_jobs]
  }

  @spec permissions() :: [atom()]
  def permissions, do: @permissions

  @spec allowed?(term(), atom()) :: boolean()
  def allowed?(%User{status: :active, role: role}, permission) when permission in @permissions do
    permission in Map.fetch!(@role_permissions, role)
  end

  def allowed?(_actor, _permission), do: false

  @spec any_allowed?(term(), [atom()]) :: boolean()
  def any_allowed?(actor, permissions), do: Enum.any?(permissions, &allowed?(actor, &1))

  @spec authorize(term(), atom()) :: :ok | {:error, :forbidden}
  def authorize(actor, permission) do
    if allowed?(actor, permission), do: :ok, else: {:error, :forbidden}
  end
end
