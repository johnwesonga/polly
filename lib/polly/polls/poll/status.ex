defmodule Polly.Polls.Poll.Status do
  use Ash.Type.Enum, values: [:draft, :open, :closed]
end
