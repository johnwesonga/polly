defmodule Polly.AuditTest do
  use Polly.DataCase

  require Ash.Query

  alias Polly.Accounts.User
  alias Polly.Audit
  alias Polly.Audit.Event
  alias Polly.Members.Member
  alias Polly.Polls.{Duplicator, Electorate, Option, Poll}

  setup do
    actor =
      Ash.create!(
        User,
        %{
          email: "audit-admin-#{System.unique_integer([:positive])}@example.com",
          password: "secure-password",
          password_confirmation: "secure-password"
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
             "poll.created"
           ]

    assert Enum.all?(Ash.read!(Event, actor: actor), &(&1.actor_id == actor.id))

    assert {:error, _error} = Ash.update(closed, %{}, action: :close, actor: actor)
    assert length(actions()) == 5
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
end
