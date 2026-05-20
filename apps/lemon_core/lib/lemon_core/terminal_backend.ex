defmodule LemonCore.TerminalBackend do
  @moduledoc """
  Behaviour for terminal/process execution backends.

  Registered backends include `:local`, backed by the existing supervised
  coding-agent `ProcessSession` Port runner, `:local_pty`, backed by
  util-linux `script(1)`, and `:docker`, backed by the Docker CLI. SSH or
  sandbox backends should implement this contract so operators can inspect
  available capabilities from LemonCore without depending on a specific runner
  app.
  """

  @type backend_id :: atom()
  @type capability :: atom()

  @callback id() :: backend_id()
  @callback label() :: String.t()
  @callback available?() :: boolean()
  @callback capabilities() :: [capability()]
  @callback metadata() :: map()
end
