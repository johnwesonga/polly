defmodule Polly.Accounts.AdminUserMigrationTest do
  use ExUnit.Case, async: true

  @migration_path "priv/repo/migrations/20260827150449_admin_user_management_phase_1.exs"

  test "backfills existing users before enforcing non-null fields" do
    migration = File.read!(@migration_path)

    schema_position = position!(migration, "CREATE TABLE users_phase_one")
    backfill_position = position!(migration, "INSERT INTO users_phase_one")
    replacement_position = position!(migration, "DROP TABLE users")

    assert schema_position < backfill_position
    assert backfill_position < replacement_position
    assert migration =~ "'owner',\n      'active'"
    assert migration =~ "role TEXT NOT NULL DEFAULT 'administrator'"
  end

  test "rollback refuses to discard ownership history" do
    migration = File.read!(@migration_path)

    assert migration =~ "def down do"
    assert migration =~ "Refusing to roll back administrator roles and statuses"
    refute migration =~ "remove :role"
  end

  defp position!(contents, pattern) do
    {position, _length} = :binary.match(contents, pattern)
    position
  end
end
