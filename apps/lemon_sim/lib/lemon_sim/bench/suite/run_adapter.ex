defmodule LemonSim.Bench.Suite.RunAdapter do
  @moduledoc false

  @type mode :: :offline | :live | :external

  @callback supported_modes() :: [mode()]
  @callback supported_presets() :: [String.t()]
  @callback preset_opts(String.t()) :: keyword()
  @callback run(mode(), String.t(), integer(), keyword()) ::
              {:ok, String.t()} | {:error, term()}
end
