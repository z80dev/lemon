defmodule LemonRouter.EngineRuntimeConfiguration do
  @moduledoc false

  require Logger

  @spec validate_configured() :: :ok | {:error, LemonCore.Contract.error()}
  def validate_configured do
    module = Application.get_env(:lemon_router, :engine_runtime)

    case validate(module) do
      :ok ->
        :ok

      {:error, reason} = error ->
        Logger.error(
          "configured :engine_runtime #{inspect(module)} does not implement " <>
            "LemonCore.EngineRuntime (#{inspect(reason)}); runtime operations will remain " <>
            "unavailable until a valid runtime is configured"
        )

        error
    end
  end

  @spec validate(term()) :: :ok | {:error, LemonCore.Contract.error()}
  def validate(nil), do: :ok
  def validate(module), do: LemonCore.EngineRuntime.validate(module)
end
