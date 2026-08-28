defmodule Polly.Repo.Migrations.AddAdministratorInvitationDeliveryStatus do
  use Ecto.Migration

  def change do
    alter table(:administrator_invitations) do
      add :delivery_status, :text, null: false, default: "queued"
      add :last_error_code, :text
    end
  end
end
