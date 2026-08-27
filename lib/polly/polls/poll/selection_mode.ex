defmodule Polly.Polls.Poll.SelectionMode do
  @moduledoc """
  Defines how many options a voter may select when submitting a ballot.

  The current `:single` mode allows exactly one option per ballot. Keeping the
  value in a dedicated Ash enum makes the poll configuration explicit and
  provides a controlled extension point for future modes such as multiple or
  ranked selection.
  """

  use Ash.Type.Enum, values: [:single]
end
