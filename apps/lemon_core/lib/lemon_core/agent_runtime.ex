defmodule LemonCore.AgentRuntime do
  @moduledoc """
  Resolves the registered agent runtime for shared runtime consumers.

  Consumers inspect and operate on tasks, sessions, extensions, run graphs and
  progress without depending on a particular agent product. An agent registers
  a module implementing `LemonCore.AgentRuntime.Provider`:

      config :lemon_core, :agent_runtime_provider, MyAgent.ControlPlaneProvider

  or, more usefully, at boot:

      LemonCore.AgentRuntime.register(MyAgent.ControlPlaneProvider)

  Runtime registration writes through to the same app-env key, so it survives
  anything that re-reads configuration.

  ## Degradation

  `call/3` never raises: a missing provider, an unimplemented callback, an
  exception, an exit and a throw all produce the caller's fallback value.
  Consumers choose an explicit fallback appropriate to their operation, including
  an unavailable or unknown-outcome error for mutations.
  """

  alias LemonCore.AgentRuntime.Provider

  @setting :agent_runtime_provider

  @doc "The registered provider module, or `nil`."
  @spec provider() :: module() | nil
  def provider, do: LemonCore.RuntimeSeam.provider(@setting)

  @doc "Whether an agent runtime is registered and loadable."
  @spec available?() :: boolean()
  def available?, do: LemonCore.RuntimeSeam.available?(provider())

  @doc """
  Registers an agent runtime provider.

  Idempotent. Returns `{:error, :not_a_provider}` for a module that cannot be
  loaded, so a caller registering optimistically at boot does not crash.
  """
  @spec register(module()) :: :ok | {:error, :not_a_provider}
  def register(module) when is_atom(module) do
    case LemonCore.RuntimeSeam.register(@setting, module) do
      :ok -> :ok
      {:error, _} -> {:error, :not_a_provider}
    end
  end

  @doc """
  Calls a provider callback, returning `fallback` if it cannot be served.

  Covers every way a call can fail to produce a value: no provider registered,
  the provider not implementing that optional callback, the call raising, the
  call exiting (a dead process behind it), and the call throwing — which is
  rare, but a provider is third-party code and a `throw` that escaped would
  crash the consumer this exists to keep answering.
  """
  @spec call(atom(), [term()], term()) :: term()
  def call(function, args, fallback) when is_atom(function) and is_list(args) do
    LemonCore.RuntimeSeam.invoke(provider(), function, args, unavailable: fallback)
  end

  @doc "The behaviour providers implement, for `@behaviour` and docs references."
  @spec behaviour() :: module()
  def behaviour, do: Provider
end
