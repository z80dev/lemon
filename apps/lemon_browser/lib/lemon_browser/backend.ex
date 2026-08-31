defmodule LemonBrowser.Backend do
  @moduledoc """
  Contract for browser execution backends.

  A backend owns transport and lifecycle only. Navigation policy, approval,
  artifact, and result-redaction rules stay above this boundary so they are
  identical for managed Chrome, paired nodes, and extension-controlled tabs.
  """

  @type result :: {:ok, term()} | {:error, term()}

  @callback id() :: atom()
  @callback available?() :: boolean()
  @callback available?(keyword()) :: boolean()
  @callback request(String.t(), map(), pos_integer(), keyword()) :: result()
  @callback status(keyword()) :: map()

  @optional_callbacks available?: 1
end
