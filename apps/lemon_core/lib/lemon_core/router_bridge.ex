defmodule LemonCore.RouterBridge do
  @moduledoc """
  Optional bridge to `:lemon_router` without compile-time coupling.

  Channel adapters and other producers can forward inbound messages and submit
  runs without depending on `:lemon_router`. `:lemon_router` configures the
  bridge at runtime.
  """

  @bridge_key :router_bridge

  @type config :: %{
          optional(:run_orchestrator) => module(),
          optional(:router) => module()
        }

  @spec configure(keyword()) :: :ok
  def configure(opts) when is_list(opts) do
    config =
      opts
      |> Enum.into(%{})
      |> Map.take([:run_orchestrator, :router])

    Application.put_env(:lemon_core, @bridge_key, config)
    :ok
  end

  @spec submit_run(map()) :: {:ok, binary()} | {:error, :unavailable} | {:error, term()}
  def submit_run(params) when is_map(params) do
    case impl(:run_orchestrator) do
      nil ->
        {:error, :unavailable}

      mod ->
        if Code.ensure_loaded?(mod) and function_exported?(mod, :submit, 1) do
          apply(mod, :submit, [params])
        else
          {:error, :unavailable}
        end
    end
  rescue
    e -> {:error, e}
  end

  @spec handle_inbound(term()) :: :ok | {:error, :unavailable} | {:error, term()}
  def handle_inbound(msg) do
    case impl(:router) do
      nil ->
        {:error, :unavailable}

      mod ->
        if Code.ensure_loaded?(mod) and function_exported?(mod, :handle_inbound, 1) do
          _ = apply(mod, :handle_inbound, [msg])
          :ok
        else
          {:error, :unavailable}
        end
    end
  rescue
    e -> {:error, e}
  end

  defp impl(key) do
    config = Application.get_env(:lemon_core, @bridge_key, %{})
    Map.get(config, key)
  end
end

