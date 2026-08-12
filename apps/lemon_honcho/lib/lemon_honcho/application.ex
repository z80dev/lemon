defmodule LemonHoncho.Application do
  @moduledoc false

  use Application

  require Logger

  alias LemonHoncho.Config

  @provider_id "honcho"
  @provider_scopes [:session, :agent, :workspace, :all]
  @provider_timeout_cap_ms 5_000

  @tools [
    {:honcho_reasoning, LemonHoncho.Tools.Reasoning},
    {:honcho_search, LemonHoncho.Tools.Search},
    {:honcho_context, LemonHoncho.Tools.Context},
    {:honcho_profile, LemonHoncho.Tools.Profile},
    {:honcho_conclude, LemonHoncho.Tools.Conclude}
  ]

  @impl true
  def start(_type, _args) do
    children =
      if Application.get_env(:lemon_honcho, :start_session_manager, true) != false do
        [LemonHoncho.SessionManager]
      else
        []
      end

    case Supervisor.start_link(children, strategy: :one_for_one, name: LemonHoncho.Supervisor) do
      {:ok, pid} ->
        contribute()
        {:ok, pid}

      error ->
        error
    end
  end

  # The platform must not know Honcho exists at compile time, so this
  # integration contributes itself on the way up. Every registration below is
  # guarded and every failure is swallowed: a partially-started runtime — a
  # release without the memory app, a test that starts this app alone — must
  # still bring `lemon_honcho` up rather than take the node down.
  defp contribute do
    config = Config.load()

    if Config.configured?(config) do
      register_memory_provider(config)
      register_context_contributor()
    else
      Logger.debug(
        "honcho: not configured; memory provider and context contributor not registered"
      )
    end

    register_tools()
  end

  # Registered only when configured, because an unregistered provider costs
  # nothing while a registered one that cannot answer adds its timeout to every
  # memory search the agent runs. The timeout is capped well below the client's
  # own: search is on the agent's path and a slow provider is a slow turn.
  defp register_memory_provider(%Config{} = config) do
    if is_pid(Process.whereis(LemonMemory.Providers)) do
      config
      |> provider_spec()
      |> LemonMemory.Providers.register_provider()
      |> log_registration("memory provider")
    else
      Logger.debug("honcho: memory provider not registered: LemonMemory.Providers not running")
    end

    :ok
  rescue
    error ->
      Logger.debug("honcho: memory provider not registered: #{inspect(error)}")
      :ok
  catch
    :exit, reason ->
      Logger.debug("honcho: memory provider not registered: #{inspect(reason)}")
      :ok
  end

  defp provider_spec(%Config{} = config) do
    %{
      id: @provider_id,
      module: LemonHoncho.MemoryProvider,
      label: "Honcho",
      source: "satellite",
      scopes: @provider_scopes,
      timeout_ms: min(config.timeout_ms, @provider_timeout_cap_ms)
    }
  end

  # Same reasoning as the provider: a contributor that is not configured would
  # only add latency to the assembly of every system prompt.
  defp register_context_contributor do
    if Code.ensure_loaded?(LemonAgent.ContextRegistry) do
      :honcho
      |> LemonAgent.ContextRegistry.register(LemonHoncho.ContextContributor)
      |> log_registration("context contributor")
    else
      Logger.debug(
        "honcho: context contributor not registered: LemonAgent.ContextRegistry absent"
      )
    end

    :ok
  rescue
    error ->
      Logger.debug("honcho: context contributor not registered: #{inspect(error)}")
      :ok
  catch
    :exit, reason ->
      Logger.debug("honcho: context contributor not registered: #{inspect(reason)}")
      :ok
  end

  # The tools register unconditionally. Each one reports "Honcho is not
  # configured" as a normal tool result rather than raising, which is the
  # convention `XApi.Tools.XSearch` set: a model that asks for memory on an
  # unconfigured host should be told so, not handed an error.
  defp register_tools do
    if Code.ensure_loaded?(LemonAgent.ToolRegistry) do
      Enum.each(@tools, fn {name, module} ->
        LemonAgent.ToolRegistry.register(name, module)
      end)
    end

    :ok
  rescue
    error ->
      Logger.debug("honcho: tools not registered: #{inspect(error)}")
      :ok
  catch
    :exit, reason ->
      Logger.debug("honcho: tools not registered: #{inspect(reason)}")
      :ok
  end

  defp log_registration(:ok, _what), do: :ok

  defp log_registration(other, what) do
    Logger.debug("honcho: #{what} not registered: #{inspect(other)}")
    :ok
  end
end
