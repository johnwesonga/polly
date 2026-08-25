defmodule Polly.Members.MemberImportTest do
  use Polly.DataCase

  require Ash.Query

  alias Polly.Accounts.User
  alias Polly.Audit.Event
  alias Polly.Members.{Member, MemberImport}

  setup do
    actor =
      Ash.create!(
        User,
        %{
          email: "import-admin-#{System.unique_integer([:positive])}@example.com",
          password: "secure-password",
          password_confirmation: "secure-password"
        },
        action: :register_with_password,
        authorize?: false
      )

    %{actor: actor}
  end

  test "previews quoted UTF-8 CSV and normalizes headers and fields" do
    csv =
      <<0xEF, 0xBB, 0xBF>> <>
        " EMAIL , NAME \r\nJAMIE@EXAMPLE.COM,  Jamie Rivera  \r\n\"morgan@example.com\",\"Morgan Lee, Jr.\"\r\n"

    assert {:ok, preview} = MemberImport.preview(csv)
    assert preview.total_count == 2
    assert preview.new_count == 2
    assert preview.invalid_count == 0

    assert Enum.map(preview.rows, &{&1.row_number, &1.name, &1.email}) == [
             {2, "Jamie Rivera", "jamie@example.com"},
             {3, "Morgan Lee, Jr.", "morgan@example.com"}
           ]
  end

  test "marks every duplicate email and invalid field without writing", %{actor: actor} do
    csv = "name,email\nFirst, SAME@example.com\nSecond,same@example.com\n,invalid\n"

    assert {:ok, preview} = MemberImport.preview(csv)
    assert preview.invalid_count == 3
    assert Enum.all?(preview.rows, &(&1.classification == :invalid))
    assert {:error, :invalid_preview} = MemberImport.commit(preview, actor)
    assert Ash.count!(Member, authorize?: false) == 0
  end

  test "classifies existing members, commits new members, and is idempotent", %{actor: actor} do
    existing =
      Ash.create!(Member, %{name: "Existing Name", email: "EXISTING@example.com"}, actor: actor)

    csv = "name,email\nChanged Name,existing@example.com\nNew Member,new@example.com\n"

    assert existing.email == "existing@example.com"
    assert {:ok, preview} = MemberImport.preview(csv)
    assert preview.new_count == 1
    assert preview.existing_count == 1

    existing_row = Enum.find(preview.rows, &(&1.classification == :existing))
    assert existing_row.existing_name == "Existing Name"

    assert {:ok, %{created_count: 1, skipped_count: 1}} = MemberImport.commit(preview, actor)
    assert Ash.count!(Member, authorize?: false) == 2

    import_event =
      Event
      |> Ash.Query.filter(action == "member_import.completed")
      |> Ash.read_one!(actor: actor)

    assert import_event.metadata == %{"created_count" => 1, "skipped_count" => 1}

    assert {:ok, repeated_preview} = MemberImport.preview(csv)

    assert {:ok, %{created_count: 0, skipped_count: 2}} =
             MemberImport.commit(repeated_preview, actor)

    assert Ash.count!(Member, authorize?: false) == 2
  end

  test "rejects malformed files, invalid headers, empty data, and anonymous commits" do
    assert {:error, _message} = MemberImport.preview(<<255>>)
    assert {:error, _message} = MemberImport.preview("name,mail\nJamie,jamie@example.com\n")
    assert {:error, _message} = MemberImport.preview("name,email\n")

    assert {:error, _message} =
             MemberImport.preview("name,email\n\"unterminated,jamie@example.com")

    assert {:ok, preview} = MemberImport.preview("name,email\nJamie,jamie@example.com\n")
    assert {:error, :unauthorized} = MemberImport.commit(preview, nil)
  end
end
