defmodule LemonSim.GameHelpers.ProviderThrottle do
  @moduledoc false

  defdelegate wrap_opts(opts), to: LemonSim.LLM.GameHelpers.ProviderThrottle
  defdelegate stop(agent), to: LemonSim.LLM.GameHelpers.ProviderThrottle
end
