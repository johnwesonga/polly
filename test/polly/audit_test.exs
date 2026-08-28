defmodule Polly.AuditTest do
  use Polly.DataCase

  require Ash.Query

  alias Polly.Accounts.User
  alias Polly.Audit
  alias Polly.Audit.Event
  alias Polly.Members.Member
  alias Polly.Polls.{Duplicator, Electorate, Option, Options, Poll}

  setup do
    actor =
      Ash.create!(
        User,
        %{
          email: "audit-admin-#{System.unique_integer([:positive])}@example.com",
          password: "secure-password",
          password_confirmation: "secure-password",
          role: :owner
        },
        action: :register_with_password,
        authorize?: false
      )

    %{actor: actor}
  end

  test "poll lifecycle actions append attributed events and failures append nothing", %{
    actor: actor
  } do
    fixture = configured_poll!(actor)
    opened = Ash.update!(fixture.poll, %{}, action: :open, actor: actor)
    closed = Ash.update!(opened, %{}, action: :close, actor: actor)
    _published = Ash.update!(closed, %{}, action: :publish_results, actor: actor)

    assert actions() == [
             "poll.results_published",
             "poll.closed",
             "poll.opened",
             "poll_electorate.member_added",
             "member.created",
             "poll_option.created",
             "poll_option.created",
             "poll.created"
           ]

    assert Enum.all?(Ash.read!(Event, actor: actor), &(&1.actor_id == actor.id))

    assert {:error, _error} = Ash.update(closed, %{}, action: :close, actor: actor)
    assert length(actions()) == 8
  end

  test "duplication creates one summary event for the new poll", %{actor: actor} do
    fixture = configured_poll!(actor)
    before_count = Ash.count!(Event, actor: actor)

    assert {:ok, result} =
             Duplicator.duplicate(
               fixture.poll,
               %{copy_options?: true, copy_electorate?: true},
               actor
             )

    events =
      Event
      |> Ash.Query.filter(target_id == ^result.poll.id)
      |> Ash.read!(actor: actor)

    assert length(events) == 1
    assert hd(events).action == "poll.duplicated"
    assert hd(events).metadata["options_copied"] == 2
    assert hd(events).metadata["members_copied"] == 1
    assert Ash.count!(Event, actor: actor) == before_count + 1
  end

  test "grant operations record IDs without recording tokens", %{actor: actor} do
    fixture = configured_poll!(actor)
    reissued = Electorate.reissue(fixture.grant, actor)
    _revoked = Electorate.revoke(reissued, actor)
    _issued = Electorate.issue(fixture.poll.id, fixture.member.id, actor)

    events = Ash.read!(Event, actor: actor)
    encoded = Jason.encode!(Enum.map(events, & &1.metadata))

    assert "poll_access_grant.reissued" in Enum.map(events, & &1.action)
    assert "poll_access_grant.revoked" in Enum.map(events, & &1.action)
    assert "poll_access_grant.issued" in Enum.map(events, & &1.action)
    refute encoded =~ fixture.grant.token
    refute encoded =~ reissued.token
  end

  test "append boundary rejects anonymous, unknown, and sensitive metadata", %{actor: actor} do
    target = %{type: "poll", id: Ash.UUID.generate(), label: "Safe poll"}

    assert {:error, :actor_required} =
             Audit.append(%{action: "poll.created", actor: nil, target: target})

    assert {:error, :unknown_action} =
             Audit.append(%{action: "arbitrary.action", actor: actor, target: target})

    assert {:error, :metadata_not_allowed} =
             Audit.append(%{
               action: "poll.created",
               actor: actor,
               target: target,
               metadata: %{token: "secret"}
             })

    assert is_nil(Ash.Resource.Info.action(Event, :update))
    assert is_nil(Ash.Resource.Info.action(Event, :destroy))
  end

  test "operation IDs make retried appends idempotent", %{actor: actor} do
    operation_id = Ash.UUID.generate()

    attributes = %{
      operation_id: operation_id,
      action: "poll.created",
      actor: actor,
      target: %{type: "poll", id: Ash.UUID.generate(), label: "One operation"}
    }

    assert {:ok, _event} = Audit.append(attributes)
    assert {:error, _error} = Audit.append(attributes)
    assert Ash.count!(Event, actor: actor) == 1
  end

  test "member changes distinguish updates and activation changes", %{actor: actor} do
    member = Ash.create!(Member, %{name: "Original", email: "original@example.com"}, actor: actor)
    member = Ash.update!(member, %{name: "Renamed"}, actor: actor)
    member = Ash.update!(member, %{active: false}, actor: actor)
    _member = Ash.update!(member, %{active: true}, actor: actor)

    events = events_for_target(member.id)

    assert Enum.map(events, & &1.action) == [
             "member.activated",
             "member.deactivated",
             "member.updated",
             "member.created"
           ]

    updated = Enum.find(events, &(&1.action == "member.updated"))
    assert updated.metadata == %{"changed_fields" => ["name"]}

    encoded =
      Jason.encode!(Enum.map(events, &Map.take(&1, [:action, :target_label, :metadata])))

    refute encoded =~ "original@example.com"
  end

  test "option CRUD and reorder operations each produce semantic events", %{actor: actor} do
    poll = Ash.create!(Poll, %{title: "Option audit", slug: "option-audit"}, actor: actor)
    first = Ash.create!(Option, %{poll_id: poll.id, label: "First", position: 1}, actor: actor)
    second = Ash.create!(Option, %{poll_id: poll.id, label: "Second", position: 2}, actor: actor)
    first = Ash.update!(first, %{label: "Updated first"}, actor: actor)
    first = Options.reorder(first, second, 3, actor)
    Ash.destroy!(first, actor: actor)

    events = events_for_target(first.id)

    assert Enum.map(events, & &1.action) == [
             "poll_option.deleted",
             "poll_option.reordered",
             "poll_option.updated",
             "poll_option.created"
           ]

    reorder = Enum.find(events, &(&1.action == "poll_option.reordered"))
    assert reorder.metadata == %{"new_position" => 2, "old_position" => 1}
  end

  test "emits safe telemetry for append outcomes", %{actor: actor} do
    handler_id = "audit-test-#{System.unique_integer([:positive])}"
    test_pid = self()

    :telemetry.attach(
      handler_id,
      [:polly, :audit, :append],
      fn name, measurements, metadata, _config ->
        send(test_pid, {name, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    assert {:ok, _event} =
             Audit.append(%{
               action: "poll.created",
               actor: actor,
               target: %{type: "poll", id: Ash.UUID.generate(), label: "Telemetry"}
             })

    assert_receive {[:polly, :audit, :append], %{count: 1, duration: duration},
                    %{action: "poll.created", status: :ok}}

    assert is_integer(duration)

    assert {:error, :unknown_action} =
             Audit.append(%{
               action: "unknown.action",
               actor: actor,
               target: %{type: "poll", id: Ash.UUID.generate(), label: "Failure"}
             })

    assert_receive {[:polly, :audit, :append], %{count: 1},
                    %{action: "unknown.action", status: :error}}
  end

  test "coverage inventory tracks every iteration two boundary" do
    inventory = Polly.Audit.Coverage.inventory()

    assert inventory[{Member, :create}] == "member.created"
    assert inventory[{Option, :update}] =~ "poll_option.reordered"
    assert inventory[{Polly.Members.MemberImport, :commit}] == "member_import.completed"
    assert inventory[{Duplicator, :duplicate}] == "poll.duplicated"
    assert Map.has_key?(Polly.Audit.Coverage.exemptions(), {Polly.Polls.Ballot, :submit})
  end

  defp configured_poll!(actor) do
    poll = Ash.create!(Poll, %{title: "Audited poll", slug: "audited-poll"}, actor: actor)
    Ash.create!(Option, %{poll_id: poll.id, label: "One", position: 1}, actor: actor)
    Ash.create!(Option, %{poll_id: poll.id, label: "Two", position: 2}, actor: actor)
    member = Ash.create!(Member, %{name: "Jamie", email: "jamie@example.com"}, actor: actor)
    {eligibility, grant} = Electorate.include_member(poll, member, actor)
    %{poll: poll, member: member, eligibility: eligibility, grant: grant}
  end

  defp actions do
    Event
    |> Ash.Query.sort(occurred_at: :desc)
    |> Ash.read!(authorize?: false)
    |> Enum.map(& &1.action)
  end

  defp events_for_target(target_id) do
    Event
    |> Ash.Query.filter(target_id == ^target_id)
    |> Ash.Query.sort(occurred_at: :desc)
    |> Ash.read!(authorize?: false)
  end
end
