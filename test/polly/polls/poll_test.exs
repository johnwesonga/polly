defmodule Polly.Polls.PollTest do
  use Polly.DataCase

  alias Polly.Accounts.User
  alias Polly.Members.Member
  alias Polly.Polls.{Eligibility, Option, Poll}

  setup do
    actor =
      Ash.create!(
        User,
        %{
          email: "poll-admin-#{System.unique_integer([:positive])}@example.com",
          password: "secure-password",
          password_confirmation: "secure-password"
        },
        action: :register_with_password,
        authorize?: false
      )

    %{actor: actor}
  end

  test "creates a single-choice draft", %{actor: actor} do
    poll = create_poll!(actor, "Team Theme")

    assert poll.status == :draft
    assert poll.selection_mode == :single
    assert poll.minimum_selections == 1
    assert poll.maximum_selections == 1
    assert poll.slug == "team-theme"
  end

  test "stores multiple-choice mode on a draft without changing safe defaults", %{actor: actor} do
    poll =
      Ash.create!(
        Poll,
        %{title: "Committee priorities", selection_mode: :multiple},
        action: :create_draft,
        actor: actor
      )

    assert poll.status == :draft
    assert poll.selection_mode == :multiple
    assert poll.minimum_selections == 1
    assert poll.maximum_selections == 1
  end

  test "creates and updates valid multiple-choice selection ranges", %{actor: actor} do
    poll =
      Ash.create!(
        Poll,
        %{
          title: "Committee priorities",
          selection_mode: :multiple,
          minimum_selections: 1,
          maximum_selections: 3
        },
        action: :create_draft,
        actor: actor
      )

    updated =
      Ash.update!(
        poll,
        %{minimum_selections: 2, maximum_selections: 4},
        action: :update_draft,
        actor: actor
      )

    assert updated.selection_mode == :multiple
    assert updated.minimum_selections == 2
    assert updated.maximum_selections == 4
  end

  test "rejects inconsistent or non-positive selection ranges", %{actor: actor} do
    assert {:error, single_error} =
             Ash.create(
               Poll,
               %{
                 title: "Invalid single choice",
                 selection_mode: :single,
                 minimum_selections: 1,
                 maximum_selections: 2
               },
               action: :create_draft,
               actor: actor
             )

    assert Exception.message(single_error) =~
             "single-choice polls must require exactly one selection"

    assert {:error, range_error} =
             Ash.create(
               Poll,
               %{
                 title: "Invalid range",
                 selection_mode: :multiple,
                 minimum_selections: 3,
                 maximum_selections: 2
               },
               action: :create_draft,
               actor: actor
             )

    assert Exception.message(range_error) =~
             "must be greater than or equal to the minimum selections"

    assert {:error, positive_error} =
             Ash.create(
               Poll,
               %{
                 title: "Non-positive range",
                 selection_mode: :multiple,
                 minimum_selections: 0,
                 maximum_selections: 2
               },
               action: :create_draft,
               actor: actor
             )

    assert Exception.message(positive_error) =~ "must be greater than or equal to 1"

    assert {:error, maximum_error} =
             Ash.create(
               Poll,
               %{
                 title: "Non-positive maximum",
                 selection_mode: :multiple,
                 minimum_selections: 1,
                 maximum_selections: 0
               },
               action: :create_draft,
               actor: actor
             )

    assert Exception.message(maximum_error) =~ "must be greater than or equal to 1"
  end

  test "selection limits cannot exceed active options when opening", %{actor: actor} do
    poll =
      Ash.create!(
        Poll,
        %{
          title: "Pick three",
          selection_mode: :multiple,
          minimum_selections: 1,
          maximum_selections: 3
        },
        actor: actor
      )

    create_option!(poll, actor, "Under the Sea", 1)
    create_option!(poll, actor, "Retro Arcade", 2)
    create_eligibility!(poll, actor)

    assert {:error, error} = Ash.update(poll, %{}, action: :open, actor: actor)
    assert Exception.message(error) =~ "maximum_selections"
    assert Exception.message(error) =~ "cannot exceed the 2 active options"

    exact_three =
      Ash.update!(
        poll,
        %{minimum_selections: 3, maximum_selections: 3},
        action: :update_draft,
        actor: actor
      )

    assert {:error, minimum_error} =
             Ash.update(exact_three, %{}, action: :open, actor: actor)

    assert Exception.message(minimum_error) =~ "minimum_selections"
    assert Exception.message(minimum_error) =~ "cannot exceed the 2 active options"

    create_option!(poll, actor, "Wild West", 3)
    assert Ash.update!(exact_three, %{}, action: :open, actor: actor).status == :open
  end

  test "requires two active options before opening", %{actor: actor} do
    poll = create_poll!(actor, "Team Theme")
    create_option!(poll, actor, "Under the Sea", 1)

    assert {:error, error} = Ash.update(poll, %{}, action: :open, actor: actor)
    assert Exception.message(error) =~ "at least two active options"
  end

  test "requires an eligible member before opening", %{actor: actor} do
    poll = create_poll!(actor, "Team Theme")
    create_option!(poll, actor, "Under the Sea", 1)
    create_option!(poll, actor, "Retro Arcade", 2)

    assert {:error, error} = Ash.update(poll, %{}, action: :open, actor: actor)
    assert Exception.message(error) =~ "at least one member is eligible"
  end

  test "opens and closes through forward-only lifecycle actions", %{actor: actor} do
    poll = create_poll!(actor, "Team Theme")
    create_option!(poll, actor, "Under the Sea", 1)
    create_option!(poll, actor, "Retro Arcade", 2)
    create_eligibility!(poll, actor)

    opened = Ash.update!(poll, %{}, action: :open, actor: actor)
    assert opened.status == :open
    assert opened.opened_at

    closed = Ash.update!(opened, %{}, action: :close, actor: actor)
    assert closed.status == :closed
    assert closed.closed_at

    assert {:error, error} = Ash.update(closed, %{}, action: :open, actor: actor)
    assert Exception.message(error) =~ "must be a draft to open"
  end

  test "freezes poll details and options after opening", %{actor: actor} do
    poll = create_poll!(actor, "Team Theme")
    first = create_option!(poll, actor, "Under the Sea", 1)
    create_option!(poll, actor, "Retro Arcade", 2)
    create_eligibility!(poll, actor)
    opened = Ash.update!(poll, %{}, action: :open, actor: actor)

    assert {:error, poll_error} =
             Ash.update(
               opened,
               %{title: "Changed", maximum_selections: 2},
               action: :update_draft,
               actor: actor
             )

    assert Exception.message(poll_error) =~ "can only be edited while in draft"

    assert {:error, option_error} = Ash.update(first, %{label: "Changed"}, actor: actor)
    assert Exception.message(option_error) =~ "options are frozen"

    assert {:error, create_error} =
             Ash.create(
               Option,
               %{poll_id: opened.id, label: "Wild West", position: 3},
               actor: actor
             )

    assert Exception.message(create_error) =~ "options are frozen"
  end

  test "regenerates the slug only when a draft title changes", %{actor: actor} do
    poll = create_poll!(actor, "Original Title")

    description_update =
      Ash.update!(
        poll,
        %{description: "A new description"},
        action: :update_draft,
        actor: actor
      )

    assert description_update.slug == "original-title"

    title_update =
      Ash.update!(
        description_update,
        %{title: "Final Title"},
        action: :update_draft,
        actor: actor
      )

    assert title_update.slug == "final-title"
  end

  test "requires an authenticated actor", %{actor: actor} do
    poll = create_poll!(actor, "Team Theme")

    assert {:ok, []} = Ash.read(Poll)

    assert {:error, %Ash.Error.Forbidden{}} =
             Ash.update(poll, %{title: "Changed"}, action: :update_draft)

    assert {:error, %Ash.Error.Forbidden{}} =
             Ash.create(Poll, %{title: "Anonymous"})
  end

  defp create_poll!(actor, title) do
    Ash.create!(
      Poll,
      %{title: title, description: "Choose a theme"},
      actor: actor
    )
  end

  defp create_option!(poll, actor, label, position) do
    Ash.create!(Option, %{poll_id: poll.id, label: label, position: position}, actor: actor)
  end

  defp create_eligibility!(poll, actor) do
    member = Ash.create!(Member, %{name: "Eligible Member"}, actor: actor)
    Ash.create!(Eligibility, %{poll_id: poll.id, member_id: member.id}, actor: actor)
  end
end
