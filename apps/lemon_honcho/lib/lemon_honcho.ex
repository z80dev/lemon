defmodule LemonHoncho do
  @moduledoc """
  Honcho-backed long-term memory for Lemon, as an optional satellite app.

  Honcho is an external service that reads a conversation and keeps a model of
  the people in it: what they prefer, how they work, what was decided. This app
  is the adapter. It writes each turn to Honcho, asks for the resulting context
  on the way into a run, and exposes the deeper queries — reasoning about the
  user, searching past sessions, reading and editing the peer card — as agent
  tools.

  Nothing in the platform names this app. `lemon_honcho` contributes itself on
  the way up (see `LemonHoncho.Application`) by registering a
  `LemonMemory.Provider`, a `LemonAgent.ContextRegistry` contributor, and its
  tools with `LemonAgent.ToolRegistry`. Remove the app from a build and the
  platform is unchanged; add it without credentials and it stays inert.

  This module is the small public face of all that: is it on, what is it
  configured as, and what does the operator need to see.

  ## Where to look

    * `LemonHoncho.Config` — every knob, and the rules for resolving them.
    * `LemonHoncho.SessionName` — which runs share one Honcho session.
    * `LemonHoncho.Client` — the HTTP surface; every call returns
      `{:ok, term()}` or `{:error, term()}` and none of them raise.
    * `LemonHoncho.SessionManager` — the process that keeps Honcho off the
      caller's path, batching uploads and caching context between turns.
  """

  require Logger

  alias LemonHoncho.Config

  @doc """
  Loads the current configuration.

  Cheap enough to call per turn — it reads the environment and the application
  env, and holds no state of its own — which is why callers pass the struct
  around rather than reaching for a cached singleton.
  """
  @spec config() :: Config.t()
  def config, do: Config.load()

  @doc """
  Whether the integration has credentials (or a base URL) and is switched on.

  This is the question to ask before doing anything that costs a caller time.
  When it is false the memory provider and context contributor are never
  registered, and the agent tools return a "not configured" result instead of
  attempting a call.
  """
  @spec configured?() :: boolean()
  def configured?, do: Config.configured?(config())

  @doc """
  Whether the operator's master switch is on.

  Distinct from `configured?/0`: an enabled integration with no API key and no
  base URL has nothing to talk to. Use this only when reporting *why* Honcho is
  inactive; use `configured?/0` to decide whether to call it.
  """
  @spec enabled?() :: boolean()
  def enabled?, do: config().enabled?

  @doc """
  A redaction-safe snapshot for operators, `mix lemon.honcho`, and support bundles.

  The API key's *value* never appears here — only `:api_key_present?` — so the
  result is safe to log, print, or paste into an issue.
  """
  @spec status() :: map()
  def status do
    config = config()

    %{
      enabled?: config.enabled?,
      configured?: Config.configured?(config),
      api_key_present?: is_binary(config.api_key),
      base_url: config.base_url,
      environment: config.environment,
      workspace: config.workspace,
      user_peer: config.user_peer,
      ai_peer: config.ai_peer,
      recall_mode: config.recall_mode,
      session_strategy: config.session_strategy,
      observation_mode: config.observation_mode,
      context_cadence: config.context_cadence,
      dialectic_cadence: config.dialectic_cadence,
      timeout_ms: config.timeout_ms,
      save_messages?: config.save_messages?,
      inject_in_subagents?: config.inject_in_subagents?,
      sessions: sessions()
    }
  end

  # The session manager is optional in a way the rest of this module is not: it
  # may be unstarted (a test run, a build with `start_session_manager: false`)
  # and it may be busy. Status is a diagnostic surface, so an unavailable
  # manager degrades to "no sessions" rather than failing the report.
  defp sessions do
    if is_pid(Process.whereis(LemonHoncho.SessionManager)) do
      LemonHoncho.SessionManager.sessions()
    else
      []
    end
  rescue
    error ->
      Logger.debug("honcho: session listing failed: #{inspect(error)}")
      []
  catch
    :exit, reason ->
      Logger.debug("honcho: session listing unavailable: #{inspect(reason)}")
      []
  end
end
