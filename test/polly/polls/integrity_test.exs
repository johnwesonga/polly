defmodule Polly.Polls.IntegrityTest do
  use Polly.DataCase

  import ExUnit.CaptureLog

  alias Polly.Accounts.User
  alias Polly.Members.Member
  alias Polly.Polls.{Ballot, Integrity, Poll, Results}

  setup do
    actor =
      Ash.create!(
        User,
        %{
          email: "integrity-admin-#{System.unique_integer([:positive])}@example.com",
          password: "secure-password",
          password_confirmation: "secure-password"
        },
        action: :register_with_password,
        authorize?: false
      )

    poll = Ash.create!(Poll, %{title: "Integrity check"}, actor: actor)
    member = Ash.create!(Member, %{name: "Integrity voter"}, actor: actor)

    %{actor: actor, poll: poll, member: member}
  end

  test "consistent aggregate counts do not emit mismatch telemetry", context do
    handler_id = "integrity-consistent-#{System.unique_integer([:positive])}"
    test_pid = self()

    :telemetry.attach(
      handler_id,
      [:polly, :polls, :integrity, :mismatch],
      fn event, measurements, metadata, _config ->
        send(test_pid, {event, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    result = Results.for_poll(context.poll)

    assert result.integrity.consistent?
    refute_receive {[:polly, :polls, :integrity, :mismatch], _measurements, _metadata}
  end

  test "reports mismatches using aggregate-only logs and telemetry", context do
    ballot =
      Ash.create!(
        Ballot,
        %{poll_id: context.poll.id, member_id: context.member.id},
        action: :submit,
        authorize?: false
      )

    handler_id = "integrity-mismatch-#{System.unique_integer([:positive])}"
    test_pid = self()

    :telemetry.attach(
      handler_id,
      [:polly, :polls, :integrity, :mismatch],
      fn event, measurements, metadata, _config ->
        send(test_pid, {event, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    log =
      capture_log(fn ->
        result = Results.for_poll(context.poll)
        refute result.integrity.consistent?
      end)

    assert log =~ "poll aggregate integrity mismatch"
    refute log =~ context.member.id
    refute log =~ ballot.id

    assert_receive {
      [:polly, :polls, :integrity, :mismatch],
      %{participation_count: 0, ballot_count: 1, difference: -1},
      %{poll_id: poll_id, privacy_mode: :identified}
    }

    assert poll_id == context.poll.id

    capture_log(fn ->
      assert {:ok, [check]} = Integrity.scan(context.actor)
      assert check.poll_id == context.poll.id
      refute check.consistent?
    end)

    assert {:error, :forbidden} = Integrity.scan(nil)
  end
end
