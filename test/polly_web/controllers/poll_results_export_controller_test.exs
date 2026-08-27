defmodule PollyWeb.PollResultsExportControllerTest do
  use PollyWeb.ConnCase

  alias Polly.Members.Member
  alias Polly.Polls.{Electorate, Option, Poll}

  test "requires an authenticated administrator", %{conn: conn} do
    poll_id = Ecto.UUID.generate()
    conn = get(conn, ~p"/admin/polls/#{poll_id}/results.csv")

    assert redirected_to(conn) == ~p"/sign-in"
    assert get_session(conn, :return_to) == ~p"/admin/polls/#{poll_id}/results.csv"
  end

  test "downloads a private, non-cacheable CSV attachment", %{conn: conn} do
    {conn, actor} = register_and_log_in_administrator(conn)
    poll = open_poll!(actor)

    conn = get(conn, ~p"/admin/polls/#{poll.id}/results.csv")

    assert response(conn, 200) =~ "poll_id,poll_title,poll_status"
    assert get_resp_header(conn, "content-type") == ["text/csv; charset=utf-8"]

    assert get_resp_header(conn, "content-disposition") ==
             [~s(attachment; filename="controller-export-results-#{Date.utc_today()}.csv")]

    assert get_resp_header(conn, "cache-control") == ["private, no-store, max-age=0"]
    assert get_resp_header(conn, "pragma") == ["no-cache"]
    assert get_resp_header(conn, "x-content-type-options") == ["nosniff"]
  end

  test "redirects draft exports back to poll results", %{conn: conn} do
    {conn, actor} = register_and_log_in_administrator(conn)
    poll = configured_poll!(actor)

    conn = get(conn, ~p"/admin/polls/#{poll.id}/results.csv")

    assert redirected_to(conn) == ~p"/admin/polls/#{poll.id}/results"
  end

  defp open_poll!(actor) do
    actor
    |> configured_poll!()
    |> Ash.update!(%{}, action: :open, actor: actor)
  end

  defp configured_poll!(actor) do
    poll =
      Ash.create!(
        Poll,
        %{title: "Controller export", slug: "controller-export"},
        actor: actor
      )

    Ash.create!(Option, %{poll_id: poll.id, label: "One", position: 1}, actor: actor)
    Ash.create!(Option, %{poll_id: poll.id, label: "Two", position: 2}, actor: actor)
    member = Ash.create!(Member, %{name: "Export voter"}, actor: actor)
    Electorate.include_member(poll, member, actor)
    poll
  end
end
