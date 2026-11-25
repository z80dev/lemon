defmodule LemonCore.AgentRuntime do
  @moduledoc """
  Resolves the registered agent runtime for shared runtime consumers.

  Consumers inspect and operate on tasks, sessions, subagents, background runs
  and native session state without depending on a particular agent product. An
  agent registers a module implementing every callback of
  `LemonCore.AgentRuntime.Provider`:

      config :lemon_core, :agent_runtime_provider, MyAgent.ControlPlaneProvider

  or, more usefully, at boot:

      LemonCore.AgentRuntime.register(MyAgent.ControlPlaneProvider)

  Runtime registration writes through to the same app-env key, so it survives
  anything that re-reads configuration.

  ## Failure policy

  Callers choose between a read and a mutation; neither raises.

    * `query/3` reads. No provider, an unimplemented callback, or a callback
      that raises, exits or throws returns an error tuple, by default
      `{:error, :unavailable}`. Reached failures are logged once at warning
      level. Consumers that can deliberately degrade do so outside the seam.
    * `mutate/2` changes runtime state. No provider or an unimplemented callback
      is `{:error, :unavailable}`: the call provably did not happen. A callback
      that raises, exits or throws may already have applied its effect, so it
      is `{:error, :outcome_unknown}`, logged once at error level, and must not
      be retried automatically.
  """

  alias LemonCore.AgentRuntime.Provider
  alias LemonCore.RuntimeSeam

  @setting :agent_runtime_provider
  @unknown {:error, :outcome_unknown}

  @doc "The registered provider module, or `nil`."
  @spec provider() :: module() | nil
  def provider, do: RuntimeSeam.provider(@setting)

  @doc "Whether an agent runtime is registered and loadable."
  @spec available?() :: boolean()
  def available?, do: RuntimeSeam.available?(provider())

  @doc """
  Registers an agent runtime provider.

  Idempotent. Returns `{:error, :not_a_provider}` for a module that cannot be
  loaded or does not implement every `LemonCore.AgentRuntime.Provider`
  callback, so a caller registering optimistically at boot does not crash.
  """
  @spec register(module()) :: :ok | {:error, :not_a_provider}
  def register(module) when is_atom(module) do
    case RuntimeSeam.register(@setting, module, Provider) do
      :ok -> :ok
      {:error, _} -> {:error, :not_a_provider}
    end
  end

  @doc """
  Reads from the runtime, returning `error` when it cannot answer.

  The default is `{:error, :unavailable}`. The caller can substitute a
  domain-specific error tuple.
  """
  @spec query(atom(), [term()], {:error, term()}) :: term()
  def query(function, args, error \\ {:error, :unavailable})

  def query(function, args, {:error, _reason} = error)
      when is_atom(function) and is_list(args) do
    RuntimeSeam.invoke(provider(), function, args,
      unavailable: error,
      log: "AgentRuntime query",
      log_level: :warning
    )
  end

  @doc """
  Changes runtime state.

  Returns the callback's result, `{:error, :unavailable}` when no provider or
  callback exists, or `{:error, :outcome_unknown}` when the callback was reached
  and raised, exited or threw.
  """
  @spec mutate(atom(), [term()]) :: term()
  def mutate(function, args) when is_atom(function) and is_list(args) do
    RuntimeSeam.invoke(provider(), function, args,
      unavailable: {:error, :unavailable},
      exception: @unknown,
      exit: @unknown,
      throw: @unknown,
      log: "AgentRuntime mutation",
      log_level: :error
    )
  end

  @doc "The behaviour providers implement, for `@behaviour` and docs references."
  @spec behaviour() :: module()
  def behaviour, do: Provider
end
