defmodule Polly.Polls.Poll.SelectionMode do
  @moduledoc """
  Defines how many options a voter may select when submitting a ballot.

  `:single` represents exactly one option per ballot. `:multiple` represents a
  configurable selection range, although configuration and submission support
  are introduced through later implementation slices.
  """

  use Ash.Type.Enum, values: [:single, :multiple]
end
