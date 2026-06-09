defmodule LemonSim.GameHelpers do
  @moduledoc false

  defdelegate get(map, key, default \\ nil), to: LemonSim.Examples.Helpers
  defdelegate fetch(map, atom_key, string_key, default \\ nil), to: LemonSim.Examples.Helpers
  defdelegate maybe_put(opts, key, value), to: LemonSim.Examples.Helpers
end
