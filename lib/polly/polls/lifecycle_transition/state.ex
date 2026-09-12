defmodule Polly.Polls.LifecycleTransition.State do
  @moduledoc "Defines the states used by a scheduled poll lifecycle transition."

  use Ash.Type.Enum, values: [:pending, :completed]
end
