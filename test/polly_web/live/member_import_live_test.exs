defmodule PollyWeb.MemberImportLiveTest do
  use PollyWeb.ConnCase

  alias Polly.Members.Member

  test "protects the member import route", %{conn: conn} do
    assert {:error, {:redirect, %{to: "/sign-in"}}} = live(conn, ~p"/admin/members/import")
  end

  test "member roster links to CSV import", %{conn: conn} do
    {conn, _actor} = register_and_log_in_administrator(conn)
    {:ok, view, _html} = live(conn, ~p"/admin/members")

    assert has_element?(view, "#import-members-link[href='/admin/members/import']")
  end

  test "previews and commits a valid member CSV", %{conn: conn} do
    {conn, actor} = register_and_log_in_administrator(conn)
    {:ok, view, _html} = live(conn, ~p"/admin/members/import")

    upload =
      file_input(view, "#member-import-upload-form", :members_csv, [
        %{
          name: "members.csv",
          content: "name,email\nJamie Rivera,JAMIE@example.com\n",
          type: "text/csv"
        }
      ])

    render_upload(upload, "members.csv")
    view |> form("#member-import-upload-form") |> render_submit()

    assert has_element?(view, "#member-import-preview")
    assert has_element?(view, "#previewed-member-csv", "members.csv")
    assert has_element?(view, "#preview-member-import[disabled]")
    assert has_element?(view, "#member-import-counts", "1")
    assert has_element?(view, "#import-row-2", "New")

    view |> element("#commit-member-import") |> render_click()
    assert_redirect(view, ~p"/admin/members")

    member = Ash.read_one!(Member, actor: actor)
    assert member.name == "Jamie Rivera"
    assert member.email == "jamie@example.com"
  end

  test "invalid preview shows row errors and disables confirmation", %{conn: conn} do
    {conn, _actor} = register_and_log_in_administrator(conn)
    {:ok, view, _html} = live(conn, ~p"/admin/members/import")

    upload =
      file_input(view, "#member-import-upload-form", :members_csv, [
        %{name: "members.csv", content: "name,email\nJamie,not-an-email\n", type: "text/csv"}
      ])

    render_upload(upload, "members.csv")
    view |> form("#member-import-upload-form") |> render_submit()

    assert has_element?(view, "#import-row-2", "Email format is invalid")
    assert has_element?(view, "#commit-member-import[disabled]")
    assert Ash.count!(Member, authorize?: false) == 0
  end
end
