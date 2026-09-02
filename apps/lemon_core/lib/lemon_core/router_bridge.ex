defmodule LemonCore.RouterBridge do
  @moduledoc """
  Bridge to `:lemon_router` without compile-time coupling.

  Channel adapters and other producers forward inbound messages and submit runs
  through this module; `:lemon_router` registers its implementation at boot
  with `configure/1`. Two roles are registered, each defined by a behaviour:

    * `:router` — `LemonCore.RouterBridge.Router`: inbound routing, aborts,
      keep-alive decisions and session queries.
    * `:run_orchestrator` — `LemonCore.RouterBridge.RunOrchestrator`:
      `submit/1` for a canonical `%LemonCore.RunRequest{}`.

  `configure/1` validates each module with `LemonCore.Contract.validate/2`, so
  a registered implementation is loadable and complete and the bridge calls it
  directly. A partial implementation, typically a test double, uses
  `use LemonCore.RouterBridge.Router` to get overridable defaults that fail
  visibly instead of answering an invented value.

  ## Failure contract

  Every function answers rather than raises, because callers are channel
  adapters and webhook handlers for whom a router problem is not their problem
  to crash over. Failure modes are deliberately distinguished, and none of
  them is silent:

    * **Not configured** — no module registered for the role:
      `{:error, :unavailable}`.
    * **Explicit callback error** — an in-contract `{:error, reason}` returned
      normally is passed through. Except for `:outcome_unknown` itself, bridge
      implementations must return an error only when they can guarantee that
      the mutation did not take effect; this is the definite-rejection path.
    * **Reached and raised** — the callback ran in the caller's process and
      raised. A read-only query returns `{:error, exception}`, while a mutation
      returns `{:error, :outcome_unknown}` because the exception may have been
      raised after the side effect. The bridge logs only the callback MFA and
      the safe failure class `exception`; exception messages and stacktraces
      may contain request data or credentials and are never rendered here.
    * **Unacknowledged mutation** — a submission, inbound route, abort, or
      keep-alive callback that raises, throws, returns a malformed
      acknowledgement, times out, or exits returns
      `{:error, :outcome_unknown}`. This includes `:noproc`: the callback may
      have applied one side effect before reaching a missing downstream
      process. The operation may already have taken effect. Callers must not
      automatically retry it unless they have an independent idempotency or
      reconciliation mechanism, because a retry can duplicate the side
      effect.

  Query callbacks are read-only, so any exit or timeout is reported as
  `{:error, :unavailable}` rather than `:outcome_unknown`; there is no side
  effect to duplicate. They never answer a soft value (`false`, `:none`, `[]`)
  for a router they could not reach. Deciding what an unknown router state
  means is the caller's job.

  Callback exits are logged at warning level, again using only the sanitized
  callback MFA and failure class (`timeout`, `no_process`, or `exit`). Throws
  are also caught without rendering their terms and logged with the fixed
  failure class `throw`; they are outcome-unknown for mutations and unavailable
  for queries. Raw exceptions, throw/exit reasons, and callback arguments are
  never formatted or inspected for logs.
  """

  alias LemonCore.Contract
  alias LemonCore.RunRequest

  require Logger

  @bridge_key :router_bridge
  @roles [
    run_orchestrator: LemonCore.RouterBridge.RunOrchestrator,
    router: LemonCore.RouterBridge.Router
  ]
  @config_keys Keyword.keys(@roles)

  @type config :: %{
          optional(:run_orchestrator) => module(),
          optional(:router) => module()
        }

  @type configure_mode :: :replace | :merge | :safe_merge
  @type unavailable :: {:error, :unavailable}
  @type outcome_unknown :: {:error, :outcome_unknown}

  @doc "The behaviour each configurable role must implement."
  @spec roles() :: keyword(module())
  def roles, do: @roles

  @spec configure(keyword()) :: :ok | {:error, term()}
  def configure(opts) when is_list(opts) do
    configure(opts, mode: :replace)
  end

  @doc """
  Configure bridge modules with merge/guard modes.

  Modes:
  - `:replace` - replace configured keys directly
  - `:merge` - merge with existing config, preserving unspecified keys
  - `:safe_merge` - like merge, but rejects conflicting non-nil overrides

  Every non-nil module is validated against its role's behaviour; a module
  that is not loadable or lacks a callback is rejected as
  `{:error, {:invalid_implementation, role, reason}}` and nothing is changed.
  """
  @spec configure(keyword(), keyword()) :: :ok | {:error, term()}
  def configure(opts, config_opts) when is_list(opts) and is_list(config_opts) do
    mode = Keyword.get(config_opts, :mode, :replace)
    incoming = opts |> Enum.into(%{}) |> Map.take(@config_keys)

    with :ok <- validate_config(incoming),
         {:ok, config} <- merge_config(current_config(), incoming, mode) do
      Application.put_env(:lemon_core, @bridge_key, config)
      :ok
    end
  end

  @doc """
  Configure bridge modules with conflict protection.
  """
  @spec configure_guarded(keyword()) :: :ok | {:error, term()}
  def configure_guarded(opts) when is_list(opts) do
    configure(opts, mode: :safe_merge)
  end

  @doc """
  Submit a canonical run request.

  Success is normalized to `{:ok, nonempty_run_id}`. A raised exception,
  thrown term, malformed acknowledgement, timeout, or ambiguous callback exit
  returns `{:error, :outcome_unknown}`: the run may have been accepted, so
  retrying can create a duplicate unless the caller reconciles the original
  request independently.
  """
  @spec submit_run(RunRequest.t()) ::
          {:ok, binary()} | unavailable() | outcome_unknown() | {:error, term()}
  def submit_run(%RunRequest{} = params) do
    :run_orchestrator
    |> call(:submit, [params], :mutation)
    |> expect_run_id()
  end

  @spec handle_inbound(term()) ::
          :ok | unavailable() | outcome_unknown() | {:error, term()}
  def handle_inbound(msg) do
    :router
    |> call(:handle_inbound, [msg], :mutation)
    |> expect_ok()
  end

  @spec abort_session(binary(), term()) ::
          :ok | unavailable() | outcome_unknown() | {:error, term()}
  def abort_session(session_key, reason \\ :user_requested)

  def abort_session(session_key, reason) when is_binary(session_key) and session_key != "" do
    :router
    |> call(:abort, [session_key, reason], :mutation)
    |> expect_ok()
  end

  def abort_session(session_key, _reason), do: {:error, {:invalid_session_key, session_key}}

  @spec abort_run(binary(), term()) ::
          :ok | unavailable() | outcome_unknown() | {:error, term()}
  def abort_run(run_id, reason \\ :user_requested)

  def abort_run(run_id, reason) when is_binary(run_id) and run_id != "" do
    :router
    |> call(:abort_run, [run_id, reason], :mutation)
    |> expect_ok()
  end

  def abort_run(run_id, _reason), do: {:error, {:invalid_run_id, run_id}}

  @spec keep_run_alive(binary(), :continue | :cancel) ::
          :ok | unavailable() | outcome_unknown() | {:error, term()}
  def keep_run_alive(run_id, decision \\ :continue)

  def keep_run_alive(run_id, decision)
      when is_binary(run_id) and run_id != "" and decision in [:continue, :cancel] do
    :router
    |> call(:keep_run_alive, [run_id, decision], :mutation)
    |> expect_ok()
  end

  def keep_run_alive(run_id, _decision) when not is_binary(run_id) or run_id == "",
    do: {:error, {:invalid_run_id, run_id}}

  def keep_run_alive(_run_id, decision),
    do: {:error, {:invalid_keep_alive_decision, decision}}

  @doc """
  Whether the session has an active run.

  `{:error, :unavailable}` when the router cannot be consulted: "not busy"
  would be the wrong answer, since a caller may then start work it would
  otherwise have queued.
  """
  @spec session_busy?(binary()) :: {:ok, boolean()} | unavailable() | {:error, term()}
  def session_busy?(session_key) when is_binary(session_key) and session_key != "" do
    case call(:router, :session_busy?, [session_key], :query) do
      busy? when is_boolean(busy?) -> {:ok, busy?}
      {:error, _} = error -> error
      other -> {:error, {:unexpected_answer, other}}
    end
  end

  def session_busy?(session_key), do: {:error, {:invalid_session_key, session_key}}

  @spec active_run(binary()) :: {:ok, binary()} | :none | unavailable() | {:error, term()}
  def active_run(session_key) when is_binary(session_key) and session_key != "" do
    case call(:router, :active_run, [session_key], :query) do
      {:ok, run_id} when is_binary(run_id) and run_id != "" -> {:ok, run_id}
      :none -> :none
      {:error, _} = error -> error
      other -> {:error, {:unexpected_answer, other}}
    end
  end

  def active_run(session_key), do: {:error, {:invalid_session_key, session_key}}

  @spec list_active_sessions() ::
          {:ok, [%{session_key: binary(), run_id: binary()}]} | unavailable() | {:error, term()}
  def list_active_sessions do
    case call(:router, :list_active_sessions, [], :query) do
      sessions when is_list(sessions) -> {:ok, sessions}
      {:error, _} = error -> error
      other -> {:error, {:unexpected_answer, other}}
    end
  end

  # ---------------------------------------------------------------------------
  # Dispatch
  # ---------------------------------------------------------------------------

  defp call(role, function, args, operation_kind) do
    case impl(role) do
      nil ->
        {:error, :unavailable}

      module ->
        invoke(module, function, args, operation_kind)
    end
  end

  defp invoke(module, function, args, operation_kind) do
    apply(module, function, args)
  rescue
    exception ->
      Logger.error(
        "RouterBridge callback failed callback=#{callback_mfa(module, function, args)} " <>
          "failure_class=exception"
      )

      exception_result(operation_kind, exception)
  catch
    :exit, reason ->
      failure_class = exit_failure_class(reason)

      Logger.warning(
        "RouterBridge callback failed callback=#{callback_mfa(module, function, args)} " <>
          "failure_class=#{failure_class}"
      )

      exit_result(operation_kind, failure_class)

    :throw, _reason ->
      Logger.error(
        "RouterBridge callback failed callback=#{callback_mfa(module, function, args)} " <>
          "failure_class=throw"
      )

      throw_result(operation_kind)
  end

  defp callback_mfa(module, function, args) do
    Exception.format_mfa(module, function, length(args))
  end

  defp exit_failure_class(:noproc), do: :no_process
  defp exit_failure_class({:noproc, _call}), do: :no_process
  defp exit_failure_class(:timeout), do: :timeout
  defp exit_failure_class({:timeout, _call}), do: :timeout
  defp exit_failure_class(_reason), do: :exit

  defp exit_result(:query, _failure_class), do: {:error, :unavailable}
  defp exit_result(:mutation, _failure_class), do: {:error, :outcome_unknown}

  defp exception_result(:query, exception), do: {:error, exception}
  defp exception_result(:mutation, _exception), do: {:error, :outcome_unknown}

  defp throw_result(:query), do: {:error, :unavailable}
  defp throw_result(:mutation), do: {:error, :outcome_unknown}

  defp expect_run_id({:ok, run_id}) when is_binary(run_id) and run_id != "",
    do: {:ok, run_id}

  defp expect_run_id({:error, _reason} = error), do: error
  defp expect_run_id(_malformed_acknowledgement), do: {:error, :outcome_unknown}

  defp expect_ok(:ok), do: :ok
  defp expect_ok({:error, _reason} = error), do: error
  defp expect_ok(_malformed_acknowledgement), do: {:error, :outcome_unknown}

  defp impl(key) do
    Map.get(current_config(), key)
  end

  defp current_config do
    case Application.get_env(:lemon_core, @bridge_key, %{}) do
      config when is_map(config) -> Map.take(config, @config_keys)
      _ -> %{}
    end
  end

  defp validate_config(config) do
    Enum.reduce_while(config, :ok, fn
      {key, nil}, :ok when key in @config_keys ->
        {:cont, :ok}

      {key, module}, :ok when key in @config_keys ->
        case Contract.validate(module, Keyword.fetch!(@roles, key)) do
          :ok -> {:cont, :ok}
          {:error, reason} -> {:halt, {:error, {:invalid_implementation, key, reason}}}
        end

      {key, module}, :ok ->
        {:halt, {:error, {:invalid_module, key, module}}}
    end)
  end

  defp merge_config(_current, incoming, :replace), do: {:ok, compact_config(incoming)}

  defp merge_config(current, incoming, :merge) do
    {:ok, current |> Map.merge(incoming) |> compact_config()}
  end

  defp merge_config(current, incoming, :safe_merge) do
    conflicts =
      Enum.filter(@config_keys, fn key ->
        current_val = Map.get(current, key)
        incoming_val = Map.get(incoming, key, :__missing__)

        current_val != nil and incoming_val not in [:__missing__, nil, current_val]
      end)

    case conflicts do
      [] ->
        merge_config(current, incoming, :merge)

      [key | _] ->
        {:error,
         {:already_configured, key, Map.get(current, key), Map.get(incoming, key, :__missing__)}}
    end
  end

  defp merge_config(_current, _incoming, mode), do: {:error, {:invalid_mode, mode}}

  defp compact_config(config) when is_map(config) do
    Enum.reduce(config, %{}, fn
      {_key, nil}, acc -> acc
      {key, value}, acc -> Map.put(acc, key, value)
    end)
  end
end
