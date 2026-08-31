defmodule Polly.Polls.Poll.ResultVisibility do
  @moduledoc "Defines who may view a poll's published aggregate results."

  use Ash.Type.Enum, values: [:credentialed, :public]
end
