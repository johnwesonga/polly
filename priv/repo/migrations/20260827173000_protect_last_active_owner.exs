defmodule Polly.Repo.Migrations.ProtectLastActiveOwner do
  use Ecto.Migration

  def up do
    execute """
    CREATE TRIGGER users_prevent_last_active_owner_update
    BEFORE UPDATE OF role, status ON users
    WHEN OLD.role = 'owner'
      AND OLD.status = 'active'
      AND (NEW.role != 'owner' OR NEW.status != 'active')
      AND (
        SELECT COUNT(*)
        FROM users
        WHERE role = 'owner' AND status = 'active'
      ) <= 1
    BEGIN
      SELECT RAISE(ABORT, 'last_active_owner');
    END
    """
  end

  def down do
    execute "DROP TRIGGER IF EXISTS users_prevent_last_active_owner_update"
  end
end
