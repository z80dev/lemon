defmodule LemonGateway.Cwd do
  @moduledoc """
  Resolves the default working directory for engine runs.

  Falls back through: configured `default_cwd` -> user home directory -> process cwd.
  """

  alias LemonCore.Cwd, as: SharedCwd

  @doc "Returns the default working directory, resolved from config, home, or process cwd."
  @spec default_cwd() :: String.t()
  def default_cwd, do: SharedCwd.default_cwd()
end
