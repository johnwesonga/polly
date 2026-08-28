defmodule Polly.Accounts.AuthorizationTest do
  use Polly.DataCase, async: false

  alias Polly.Accounts.{Authorization, User}
  alias Polly.Audit.Event
  alias Polly.Members.Member

  alias Polly.Polls.{
    AccessGrant,
    Ballot,
    Eligibility,
    InvitationDelivery,
    Option,
    Poll,
    Selection
  }

  @expected %{
    owner: Authorization.permissions() -- [:operate_jobs],
    administrator: [
      :manage_members,
      :manage_polls,
      :manage_electorates,
      :manage_access_grants,
      :send_invitations,
      :view_results,
      :publish_results,
      :export_results,
      :export_access_links
    ],
    auditor: [:view_results, :export_results, :view_audit],
    operator: [:view_jobs]
  }

  test "the role matrix is explicit and disabled users have no permissions" do
    for {role, expected_permissions} <- @expected,
        permission <- Authorization.permissions() do
      actor = %User{role: role, status: :active}
      assert Authorization.allowed?(actor, permission) == permission in expected_permissions
    end

    for role <- Map.keys(@expected), permission <- Authorization.permissions() do
      refute Authorization.allowed?(%User{role: role, status: :disabled}, permission)
    end
  end

  test "resource reads enforce the role matrix" do
    actors = Map.new(Map.keys(@expected), &{&1, create_user!(&1)})
    owner = actors.owner
    member = Ash.create!(Member, %{name: "Visible member"}, actor: owner)
    poll = Ash.create!(Poll, %{title: "Visible poll", slug: "visible-poll"}, actor: owner)

    option =
      Ash.create!(Option, %{poll_id: poll.id, label: "Visible option", position: 1}, actor: owner)

    eligibility =
      Ash.create!(Eligibility, %{poll_id: poll.id, member_id: member.id}, actor: owner)

    grant = Ash.create!(AccessGrant, %{poll_id: poll.id, member_id: member.id}, actor: owner)

    ballot =
      Ash.create!(
        Ballot,
        %{poll_id: poll.id, member_id: member.id},
        action: :submit,
        authorize?: false
      )

    Ash.create!(
      Selection,
      %{ballot_id: ballot.id, option_id: option.id},
      action: :select,
      authorize?: false
    )

    delivery =
      Ash.create!(
        InvitationDelivery,
        %{
          poll_id: poll.id,
          member_id: member.id,
          access_grant_id: grant.id,
          requested_by_id: owner.id,
          operation_id: Ash.UUID.generate(),
          kind: :initial,
          dedupe_key: Ash.UUID.generate(),
          recipient_email: "recipient@example.com"
        },
        action: :queue,
        actor: owner
      )

    assert eligibility.poll_id == poll.id

    expectations = [
      {Member, [:owner, :administrator]},
      {Poll, [:owner, :administrator, :auditor]},
      {Option, [:owner, :administrator, :auditor]},
      {Eligibility, [:owner, :administrator]},
      {AccessGrant, [:owner, :administrator]},
      {Ballot, [:owner, :administrator, :auditor]},
      {Selection, [:owner, :administrator, :auditor]},
      {InvitationDelivery, [:owner, :administrator, :auditor, :operator]},
      {Event, [:owner, :auditor]}
    ]

    for {resource, allowed_roles} <- expectations, {role, actor} <- actors do
      allowed? = role in allowed_roles

      case Ash.read(resource, actor: actor) do
        {:ok, records} when allowed? ->
          refute records == [], "expected #{role} to read #{inspect(resource)}"

        {:ok, records} ->
          assert records == [], "#{role} leaked records from #{inspect(resource)}"

        {:error, %Ash.Error.Forbidden{}} when not allowed? ->
          :ok

        other ->
          flunk("unexpected #{inspect(resource)} read result for #{role}: #{inspect(other)}")
      end
    end

    assert {:ok, owner_visible_users} = Ash.read(User, actor: actors.owner)
    assert length(owner_visible_users) == 4

    for role <- [:administrator, :auditor, :operator] do
      assert {:ok, []} = Ash.read(User, actor: actors[role])
    end

    assert Ash.get!(InvitationDelivery, delivery.id, actor: actors.owner).recipient_email ==
             "recipient@example.com"

    for role <- [:auditor, :operator] do
      redacted = Ash.get!(InvitationDelivery, delivery.id, actor: actors[role])
      assert %Ash.ForbiddenField{} = redacted.recipient_email
      assert %Ash.ForbiddenField{} = redacted.provider_message_id
    end
  end

  test "poll mutations are independently denied to read-only roles" do
    for role <- [:owner, :administrator] do
      actor = create_user!(role)

      assert {:ok, %Poll{}} =
               Ash.create(Poll, %{title: "#{role} poll", slug: "#{role}-poll"}, actor: actor)
    end

    for role <- [:auditor, :operator] do
      actor = create_user!(role)

      assert {:error, %Ash.Error.Forbidden{}} =
               Ash.create(Poll, %{title: "Denied #{role}", slug: "denied-#{role}"}, actor: actor)
    end
  end

  defp create_user!(role) do
    Ash.create!(
      User,
      %{
        email: "authorization-#{role}-#{System.unique_integer([:positive])}@example.com",
        password: "secure-password",
        password_confirmation: "secure-password",
        role: role
      },
      action: :register_with_password,
      authorize?: false
    )
  end
end
