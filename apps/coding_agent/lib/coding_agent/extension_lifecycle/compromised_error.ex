defmodule CodingAgent.ExtensionLifecycle.CompromisedError do
  @moduledoc """
  Raised when a session start or extension reload is attempted after an
  extension module collision set the runtime-wide compromise latch
  (`CodingAgent.Extensions.compromised?/0`). The latch clears only on restart.
  """

  defexception message: "extension module collision detected; restart the runtime"
end
