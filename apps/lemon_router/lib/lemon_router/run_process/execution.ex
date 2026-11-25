defmodule LemonRouter.RunProcess.Execution do
  @moduledoc """
  Executor-facing helpers for `LemonRouter.RunProcess`.

  The run process calls its executor (`CodingAgent.Executor` unless a test
  passes `:executor`) directly. These helpers keep exceptions from the
  executor's start and control callbacks inside the owner, and convert the
  executor's lifecycle events (`CodingAgent.Executor.Event`) into the bus
  payloads published on `run:<run_id>`.
  """

  require Logger

  import CodingAgent.Executor.Event, only: [is_started: 1, is_action_event: 1, is_completed: 1]

  alias LemonCore.{Events, ExecutionCommand, ResumeToken}

  @engine "lemon"
  @banner_bytes 1_024
  @max_logged_error_bytes 4_096

  @doc """
  The executor a run process uses: its `:executor` option, else the native
  `CodingAgent.Executor`. Tests that drive runs through the public router API
  may set `config :lemon_router, :test_executor`; no shipped config sets it.
  """
  @spec executor(map() | keyword()) :: module()
  def executor(opts),
    do:
      opts[:executor] || Application.get_env(:lemon_router, :test_executor, CodingAgent.Executor)

  @doc "Engine-session claim key: a shared resume token, else the session."
  @spec claim_key(ExecutionCommand.t()) :: term()
  def claim_key(%ExecutionCommand{resume: %ResumeToken{value: value}}) when is_binary(value),
    do: {:resume, value}

  def claim_key(%ExecutionCommand{session_key: session_key}), do: {:session, session_key}

  @doc "Working directory for the executor: the command's, or the default."
  @spec cwd(ExecutionCommand.t()) :: String.t()
  def cwd(%ExecutionCommand{cwd: cwd}) when is_binary(cwd) do
    if String.trim(cwd) == "", do: LemonCore.Cwd.default_cwd(), else: Path.expand(cwd)
  end

  def cwd(_command), do: LemonCore.Cwd.default_cwd()

  @doc """
  Start the executor. An exception, exit or malformed result is a start
  failure with a bounded reason; the executor never crashes the owner.
  """
  @spec start(module(), ExecutionCommand.t(), keyword(), pid()) ::
          {:ok, reference(), term()} | {:error, term()}
  def start(executor, command, opts, sink) do
    case executor.start_run(command, opts, sink) do
      {:ok, run_ref, control_ctx} -> {:ok, run_ref, control_ctx}
      {:error, reason} -> {:error, reason}
      other -> {:error, {:invalid_executor_start_result, other}}
    end
  rescue
    error ->
      banner = truncate(Exception.format_banner(:error, error), @banner_bytes)

      Logger.error(
        "RunProcess executor start raised executor=#{inspect(executor)} error=#{banner}"
      )

      {:error, "executor_start_exception: " <> Exception.message(error)}
  catch
    :exit, reason ->
      Logger.error(
        "RunProcess executor start exited executor=#{inspect(executor)} " <>
          "reason=#{LemonCore.StatusRedaction.inspect_reason(reason)}"
      )

      {:error, "executor_start_exit: " <> inspect(reason, limit: 20)}

    kind, reason ->
      Logger.error(
        "RunProcess executor start threw executor=#{inspect(executor)} kind=#{inspect(kind)}"
      )

      {:error, "executor_start_throw: " <> inspect({kind, reason}, limit: 20)}
  end

  @doc "Invoke an executor control callback (`cancel`, `steer`, `redirect`) safely."
  @spec control(module(), :cancel | :steer | :redirect, term(), String.t() | nil) ::
          :ok | {:error, term()}
  def control(executor, callback, control_ctx, text \\ nil) do
    if is_nil(text),
      do: apply(executor, callback, [control_ctx]),
      else: apply(executor, callback, [control_ctx, text])
  rescue
    error ->
      banner = truncate(Exception.format_banner(:error, error), @banner_bytes)
      Logger.error("RunProcess executor #{callback} raised error=#{banner}")
      {:error, :executor_control_exception}
  catch
    :exit, _reason ->
      Logger.error("RunProcess executor #{callback} exited")
      {:error, :executor_control_exit}

    _kind, _reason ->
      Logger.error("RunProcess executor #{callback} threw")
      {:error, :executor_control_throw}
  end

  @doc "The executor's runner process, monitored as the run's execution."
  @spec runner_pid(term()) :: pid() | nil
  def runner_pid(%{runner_pid: pid}) when is_pid(pid), do: pid
  def runner_pid(_control_ctx), do: nil

  @doc "Classify an executor exit without exposing its term."
  @spec exit_class(term()) :: atom()
  def exit_class(reason) when reason in [:normal, :killed, :shutdown], do: reason
  def exit_class({:shutdown, _}), do: :shutdown
  def exit_class(_reason), do: :crashed

  @doc "Bus event meta shared by every event of the run."
  @spec event_meta(binary(), binary(), ExecutionCommand.t()) :: map()
  def event_meta(run_id, session_key, %ExecutionCommand{} = command) do
    meta = %{run_id: run_id, session_key: session_key}
    meta = put_present(meta, :origin, meta_field(command, :origin))
    # A client that attached mid-run still learns the model at `run_completed`.
    put_present(meta, :model, meta_field(command, :model))
  end

  @doc "Request meta value, atom- or string-keyed."
  @spec meta_field(ExecutionCommand.t(), atom()) :: term()
  def meta_field(%ExecutionCommand{meta: meta}, key) when is_map(meta) do
    case Map.get(meta, key) do
      nil -> Map.get(meta, Atom.to_string(key))
      value -> value
    end
  end

  def meta_field(_command, _key), do: nil

  @doc "The `:run_started` payload published before the executor starts."
  @spec run_started(binary(), binary(), ExecutionCommand.t()) :: Events.RunStarted.t()
  def run_started(run_id, session_key, command) do
    Events.RunStarted.new(%{
      run_id: run_id,
      session_key: session_key,
      engine: @engine,
      model: meta_field(command, :model),
      thinking_level: meta_field(command, :thinking_level)
    })
  end

  @doc "Bus type and payload for an executor lifecycle event."
  @spec engine_event(map()) :: {atom(), map()}
  def engine_event(event) when is_started(event), do: {:engine_started, started_map(event)}
  def engine_event(event) when is_completed(event), do: {:engine_completed, completion(event)}
  def engine_event(event) when is_action_event(event), do: {:engine_action, action_event(event)}
  def engine_event(event) when is_map(event), do: {:engine_event, event}

  @doc "Typed completion payload for a `:completed` executor event."
  @spec completion(map()) :: Events.Completion.t()
  def completion(event) when is_map(event) do
    Events.Completion.from_map(%{
      engine: Map.get(event, :engine),
      resume: resume_map(Map.get(event, :resume)),
      ok: Map.get(event, :ok),
      answer: Map.get(event, :answer),
      error: Map.get(event, :error),
      usage: Map.get(event, :usage),
      meta: Map.get(event, :meta),
      run_id: Map.get(event, :run_id),
      session_key: Map.get(event, :session_key)
    })
  end

  @doc "Log a failed completion at warning (cancellation-like) or error level."
  @spec log_failure(binary(), binary(), map()) :: :ok
  def log_failure(run_id, session_key, completed) do
    error = Map.get(completed, :error)

    message =
      "RunProcess run failed run_id=#{inspect(run_id)} session_key=#{inspect(session_key)} " <>
        "error=#{format_error(error)} answer_bytes=#{byte_size(Map.get(completed, :answer) || "")}"

    if error in [:user_requested, :interrupted, :new_session, :runtime_restart],
      do: Logger.warning(message),
      else: Logger.error(message)
  end

  defp started_map(event) do
    %{
      engine: Map.get(event, :engine),
      resume: resume_map(Map.get(event, :resume)),
      title: Map.get(event, :title),
      meta: Map.get(event, :meta),
      run_id: Map.get(event, :run_id),
      session_key: Map.get(event, :session_key)
    }
  end

  defp action_event(event) do
    Events.EngineAction.from_map(%{
      engine: Map.get(event, :engine),
      action: action_map(Map.get(event, :action)),
      phase: Map.get(event, :phase),
      ok: Map.get(event, :ok),
      message: Map.get(event, :message),
      level: Map.get(event, :level)
    })
  end

  defp action_map(action) when is_map(action) do
    %{
      id: Map.get(action, :id),
      kind: Map.get(action, :kind),
      title: Map.get(action, :title),
      detail: Map.get(action, :detail)
    }
  end

  defp action_map(_action), do: nil

  defp resume_map(%ResumeToken{engine: engine, value: value}), do: %{engine: engine, value: value}
  defp resume_map(%{engine: engine, value: value}), do: %{engine: engine, value: value}
  defp resume_map(_resume), do: nil

  defp put_present(map, _key, nil), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)

  defp format_error(error) when is_binary(error), do: truncate(error, @max_logged_error_bytes)
  defp format_error(error) when is_atom(error), do: Atom.to_string(error)

  defp format_error(error) do
    error
    |> inspect(limit: 50, printable_limit: @max_logged_error_bytes)
    |> truncate(@max_logged_error_bytes)
  end

  defp truncate(text, max_bytes) when byte_size(text) <= max_bytes, do: text

  defp truncate(text, max_bytes) do
    prefix = text |> binary_part(0, max_bytes) |> valid_prefix()
    "#{prefix}...[truncated #{byte_size(text) - byte_size(prefix)} bytes]"
  end

  defp valid_prefix(binary) do
    if String.valid?(binary),
      do: binary,
      else: valid_prefix(binary_part(binary, 0, byte_size(binary) - 1))
  end
end
