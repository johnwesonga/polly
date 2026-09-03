defmodule Polly.Polls.Poll.PrivacyMode do
  @moduledoc """
  Defines whether submitted choices retain a member association.

  `:identified` preserves Polly's existing member-linked ballot behavior.
  `:anonymous` will track participation separately while storing choices
  without member identity once anonymous submission support is enabled.
  """

  use Ash.Type.Enum, values: [:identified, :anonymous]
end
