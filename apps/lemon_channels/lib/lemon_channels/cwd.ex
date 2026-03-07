defmodule LemonChannels.Cwd do
  @moduledoc false

  alias LemonCore.Cwd, as: SharedCwd

  @spec default_cwd() :: String.t()
  def default_cwd, do: SharedCwd.default_cwd()
end
