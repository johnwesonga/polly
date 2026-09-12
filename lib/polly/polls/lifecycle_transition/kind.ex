defmodule Polly.Polls.LifecycleTransition.Kind do
  @moduledoc "Defines the poll lifecycle changes that may be scheduled."

  use Ash.Type.Enum, values: [:open, :close]
end
