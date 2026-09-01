defmodule Polly.Polls.ResultExportTest do
  use Polly.DataCase

  require Ash.Query

  alias Polly.Accounts.User
  alias Polly.Audit.Event
  alias Polly.Members.Member
  alias Polly.Polls.{Ballots, Electorate, Option, Poll, ResultCSV, ResultExport}

  setup do
    actor =
      Ash.create!(
        User,
        %{
          email: "result-export-#{System.unique_integer([:positive])}@example.com",
          password: "secure-password",
          password_confirmation: "secure-password"
        },
        action: :register_with_password,
        authorize?: false
      )

    %{actor: actor}
  end

  test "exports an aggregate, formula-safe result snapshot and audits it", %{actor: actor} do
    fixture = configured_poll!(actor, "=Quarterly Results", 2)
    poll = Ash.update!(fixture.poll, %{}, action: :open, actor: actor)

    {:ok, _ballot} =
      Ballots.submit(poll.id, fixture.grants |> hd() |> voting_token(), [fixture.first.id])

    now = ~U[2026-08-26 18:30:00.000000Z]

    assert {:ok, export} = ResultExport.generate(poll.id, actor: actor, now: now)
    csv = IO.iodata_to_binary(export.iodata)
    [headers | rows] = ResultCSV.parse_string(csv, skip_headers: false)

    assert headers ==
             ~w(poll_id poll_title poll_status result_state selection_mode minimum_selections maximum_selections eligible_members ballots_submitted turnout_percentage total_selections option_position option_label selection_count percentage_of_ballots rank leading exported_at)

    assert export.filename == "quarterly-results-results-2026-08-26.csv"
    assert export.row_count == 2
    assert export.result_state == "provisional"

    [first, second] = rows
    assert Enum.at(first, 0) == poll.id
    assert Enum.at(first, 1) == "'=Quarterly Results"
    assert Enum.at(first, 3) == "provisional"
    assert Enum.at(first, 4) == "single"
    assert Enum.at(first, 5) == "1"
    assert Enum.at(first, 6) == "1"
    assert Enum.at(first, 8) == "1"
    assert Enum.at(first, 9) == "50.0"
    assert Enum.at(first, 12) == "'+Formula option"
    assert Enum.at(first, 13) == "1"
    assert Enum.at(first, 14) == "100.0"
    assert Enum.at(first, 15) == "1"
    assert Enum.at(first, 16) == "true"
    assert Enum.at(first, 17) == "2026-08-26T18:30:00.000000Z"
    assert Enum.at(second, 13) == "0"
    assert Enum.at(second, 14) == "0.0"
    refute csv =~ "Voter 1"
    refute csv =~ voting_token(hd(fixture.grants))

    event =
      Event
      |> Ash.Query.filter(action == "poll.results_exported")
      |> Ash.read_one!(authorize?: false)

    assert event.metadata == %{
             "eligible_count" => 2,
             "option_count" => 2,
             "poll_status" => "open",
             "provisional" => true,
             "result_state" => "provisional",
             "submitted_count" => 1
           }

    refute Jason.encode!(event.metadata) =~ "Formula option"
  end

  test "exports zero-valued option rows for an open poll without ballots", %{actor: actor} do
    fixture = configured_poll!(actor, "No responses", 1)
    poll = Ash.update!(fixture.poll, %{}, action: :open, actor: actor)

    assert {:ok, export} = ResultExport.generate(poll.id, actor: actor)

    [_headers | rows] =
      export.iodata
      |> IO.iodata_to_binary()
      |> ResultCSV.parse_string(skip_headers: false)

    assert length(rows) == 2

    assert Enum.all?(rows, fn row ->
             Enum.at(row, 8) == "0" and Enum.at(row, 9) == "0.0" and
               Enum.at(row, 13) == "0" and Enum.at(row, 14) == "0.0" and
               Enum.at(row, 15) == "" and Enum.at(row, 16) == "false"
           end)
  end

  test "rejects anonymous requests and draft polls", %{actor: actor} do
    fixture = configured_poll!(actor, "Draft export", 1)

    assert {:error, :unauthorized} = ResultExport.generate(fixture.poll.id, actor: nil)
    assert {:error, :poll_not_open} = ResultExport.generate(fixture.poll.id, actor: actor)

    refute Event
           |> Ash.Query.filter(action == "poll.results_exported")
           |> Ash.exists?(actor: actor)
  end

  defp configured_poll!(actor, title, member_count) do
    poll =
      Ash.create!(Poll, %{title: title}, actor: actor)

    first =
      Ash.create!(Option, %{poll_id: poll.id, label: "+Formula option", position: 1},
        actor: actor
      )

    Ash.create!(Option, %{poll_id: poll.id, label: "Standard option", position: 2}, actor: actor)

    grants =
      Enum.map(1..member_count, fn index ->
        member = Ash.create!(Member, %{name: "Voter #{index}"}, actor: actor)
        {_eligibility, grant} = Electorate.include_member(poll, member, actor)
        grant
      end)

    %{poll: poll, first: first, grants: grants}
  end
end
