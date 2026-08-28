defmodule Polly.Repo.Migrations.AddAdministratorInvitations do
  use Ecto.Migration

  def change do
    create table(:administrator_invitations, primary_key: false) do
      add :id, :uuid, primary_key: true, null: false
      add :email, :citext, null: false
      add :role, :text, null: false
      add :status, :text, null: false, default: "pending"
      add :invited_by_id, references(:users, type: :uuid), null: false
      add :accepted_user_id, references(:users, type: :uuid)
      add :expires_at, :utc_datetime_usec, null: false
      add :sent_at, :utc_datetime_usec
      add :send_count, :integer, null: false, default: 0
      add :revoked_at, :utc_datetime_usec
      add :accepted_at, :utc_datetime_usec
      timestamps(type: :utc_datetime_usec)
    end

    create index(:administrator_invitations, [:invited_by_id])

    create unique_index(:administrator_invitations, [:email],
             where: "status = 'pending'",
             name: :administrator_invitations_pending_email_index
           )
  end
end
