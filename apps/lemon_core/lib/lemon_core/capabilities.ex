defmodule LemonCore.Capabilities do
  @moduledoc """
  Capabilities a product can require of lemon_core before it boots.

  A product lists the capabilities it cannot run without:

      config :lemon_core, :required_capabilities, [:durable_store, :run_history]

  In the `:runtime` boot mode, `LemonCore.Application` checks them before it
  starts any process. When one is unavailable it logs why and how to fix it
  and fails to start with `{:missing_capability, capability}`, so the product
  stops at boot instead of running with the capability silently absent. A
  library consumer requires nothing unless it configures this list; one-shot
  client boot modes are not checked.

  | Capability | Available when |
  |---|---|
  | `:durable_store` | the default `LemonCore.Store`'s configured backend is durable (`c:LemonCore.Store.Backend.durable?/0`) |
  | `:run_history` | the `:run_history` service group is selected and the optional `:exqlite` is loaded |
  | `:runtime_control` | the `:runtime_control` service group is selected |

  Service groups are selected with `config :lemon_core, :services`; see
  `LemonCore.Application.service_groups/0`.
  """

  @type capability :: :durable_store | :run_history | :runtime_control

  @capabilities [:durable_store, :run_history, :runtime_control]

  @doc "Every capability a product can require."
  @spec names() :: [capability()]
  def names, do: @capabilities

  @doc """
  The capabilities this node's product requires: `config :lemon_core,
  :required_capabilities`, empty when unset.

  Raises `ArgumentError` for a value that is not a list of known capabilities.
  """
  @spec required() :: [capability()]
  def required do
    case Application.get_env(:lemon_core, :required_capabilities, []) do
      required when is_list(required) ->
        case Enum.reject(required, &(&1 in @capabilities)) do
          [] ->
            Enum.uniq(required)

          unknown ->
            raise ArgumentError,
                  "config :lemon_core, :required_capabilities names unknown capabilities " <>
                    "#{inspect(unknown)}; known: #{inspect(@capabilities)}"
        end

      other ->
        raise ArgumentError,
              "config :lemon_core, :required_capabilities must be a list, got: #{inspect(other)}"
    end
  end

  @doc """
  Checks `required` against the selected service `groups`, in order.

  Returns `:ok`, or `{:error, {:missing_capability, capability, reason}}` for
  the first unavailable capability, where `reason` says why and how to fix it.
  """
  @spec check([capability()], [LemonCore.Application.service_group()]) ::
          :ok | {:error, {:missing_capability, capability(), String.t()}}
  def check(required, groups) do
    Enum.reduce_while(required, :ok, fn capability, :ok ->
      case unavailable(capability, groups) do
        nil -> {:cont, :ok}
        reason -> {:halt, {:error, {:missing_capability, capability, reason}}}
      end
    end)
  end

  defp unavailable(:durable_store, _groups) do
    backend = LemonCore.Store.configured_backend()

    unless Code.ensure_loaded?(backend) and function_exported?(backend, :durable?, 0) and
             backend.durable?() do
      "the store backend #{inspect(backend)} does not persist data across restarts. " <>
        "Configure a durable backend (config :lemon_core, LemonCore.Store, " <>
        "backend: LemonCore.Store.SqliteBackend, which needs the optional :exqlite dependency)."
    end
  end

  defp unavailable(:run_history, groups) do
    cond do
      :run_history not in groups ->
        "the :run_history service group is not selected in config :lemon_core, :services."

      not Code.ensure_loaded?(Exqlite.Sqlite3) ->
        "run history needs the optional :exqlite dependency, which is not available. " <>
          ~s(Add {:exqlite, "~> 0.34"} to your deps.)

      true ->
        nil
    end
  end

  defp unavailable(:runtime_control, groups) do
    if :runtime_control not in groups do
      "the :runtime_control service group is not selected in config :lemon_core, :services."
    end
  end
end
