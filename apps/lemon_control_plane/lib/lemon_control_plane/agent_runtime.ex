defmodule LemonControlPlane.AgentRuntime do
  @moduledoc """
  Resolves the registered agent runtime for the control plane's ops methods.

  The control plane reports on a running agent — its tasks, sessions,
  extensions, run graph and progress — without depending on a particular agent
  product. An agent registers a module implementing
  `LemonControlPlane.AgentRuntime.Provider`:

      config :lemon_control_plane, :agent_runtime_provider, MyAgent.ControlPlaneProvider

  or, more usefully, at boot:

      LemonControlPlane.AgentRuntime.register(MyAgent.ControlPlaneProvider)

  Runtime registration writes through to the same app-env key, so it survives
  anything that re-reads configuration.

  ## Degradation

  `call/3` is the only way methods reach the provider, and it never raises: a
  missing provider, an unimplemented callback, an exception, an exit and a
  throw all produce the caller's fallback value. That is what keeps every ops
  method answering with an empty or "unavailable" payload — the shape ACP
  clients already expect — in a runtime with no agent installed.
  """

  alias LemonControlPlane.AgentRuntime.Provider

  @setting :agent_runtime_provider

  @doc "The registered provider module, or `nil`."
  @spec provider() :: module() | nil
  def provider do
    case Application.get_env(:lemon_control_plane, @setting) do
      module when is_atom(module) and not is_nil(module) -> module
      _ -> nil
    end
  end

  @doc "Whether an agent runtime is registered and loadable."
  @spec available?() :: boolean()
  def available? do
    case provider() do
      nil -> false
      module -> Code.ensure_loaded?(module)
    end
  end

  @doc """
  Registers an agent runtime provider.

  Idempotent. Returns `{:error, :not_a_provider}` for a module that cannot be
  loaded, so a caller registering optimistically at boot does not crash.
  """
  @spec register(module()) :: :ok | {:error, :not_a_provider}
  def register(module) when is_atom(module) do
    if Code.ensure_loaded?(module) do
      Application.put_env(:lemon_control_plane, @setting, module)
      :ok
    else
      {:error, :not_a_provider}
    end
  end

  @doc """
  Calls a provider callback, returning `fallback` if it cannot be served.

  Covers every way a call can fail to produce a value: no provider registered,
  the provider not implementing that optional callback, the call raising, the
  call exiting (a dead process behind it), and the call throwing — which is
  rare, but a provider is third-party code and a `throw` that escaped would
  crash the ops method this exists to keep answering.
  """
  @spec call(atom(), [term()], term()) :: term()
  def call(function, args, fallback) when is_atom(function) and is_list(args) do
    with module when not is_nil(module) <- provider(),
         true <- Code.ensure_loaded?(module),
         true <- function_exported?(module, function, length(args)) do
      apply(module, function, args)
    else
      _ -> fallback
    end
  rescue
    _ -> fallback
  catch
    _kind, _reason -> fallback
  end

  @doc "The behaviour providers implement, for `@behaviour` and docs references."
  @spec behaviour() :: module()
  def behaviour, do: Provider
end
