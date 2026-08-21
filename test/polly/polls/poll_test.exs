defmodule Polly.Polls.PollTest do
  use Polly.DataCase

  alias Polly.Accounts.User
  alias Polly.Polls.{Option, Poll}

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
    assert poll.slug == "team-theme"
  end

  test "requires two active options before opening", %{actor: actor} do
    poll = create_poll!(actor, "Team Theme")
    create_option!(poll, actor, "Under the Sea", 1)

    assert {:error, error} = Ash.update(poll, %{}, action: :open, actor: actor)
    assert Exception.message(error) =~ "at least two active options"
  end

  test "opens and closes through forward-only lifecycle actions", %{actor: actor} do
    poll = create_poll!(actor, "Team Theme")
    create_option!(poll, actor, "Under the Sea", 1)
    create_option!(poll, actor, "Retro Arcade", 2)

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
    opened = Ash.update!(poll, %{}, action: :open, actor: actor)

    assert {:error, poll_error} =
             Ash.update(opened, %{title: "Changed"}, action: :update_draft, actor: actor)

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

  test "requires an authenticated actor", %{actor: actor} do
    poll = create_poll!(actor, "Team Theme")

    assert {:ok, []} = Ash.read(Poll)

    assert {:error, %Ash.Error.Forbidden{}} =
             Ash.update(poll, %{title: "Changed"}, action: :update_draft)

    assert {:error, %Ash.Error.Forbidden{}} =
             Ash.create(Poll, %{title: "Anonymous", slug: "anonymous"})
  end

  defp create_poll!(actor, title) do
    Ash.create!(
      Poll,
      %{title: title, description: "Choose a theme", slug: Polly.Polls.Slug.from_title(title)},
      actor: actor
    )
  end

  defp create_option!(poll, actor, label, position) do
    Ash.create!(Option, %{poll_id: poll.id, label: label, position: position}, actor: actor)
  end
end
