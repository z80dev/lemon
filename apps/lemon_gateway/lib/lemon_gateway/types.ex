defmodule LemonGateway.Types do
  @moduledoc """
  Core type definitions for the LemonGateway domain.

  Defines the foundational types used throughout the gateway.
  `ChatScope`, `ResumeToken`, and `Binding` have been consolidated
  into `LemonCore` as canonical types.
  """

  @type lane :: :main | :subagent | :background_exec
end
