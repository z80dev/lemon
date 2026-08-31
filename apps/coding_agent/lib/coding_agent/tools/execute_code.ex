defmodule CodingAgent.Tools.ExecuteCode do
  @moduledoc """
  Programmatic tool calling: the model submits a python3 script, the script
  calls agent tools through pre-imported helper functions, and the script's
  *result* reaches the model through an explicit channel rather than by
  accident of stdout.

  This is the context lever. A script can read fifty files, grep a whole tree,
  or fetch a page and then emit a three-line summary; the intermediate tool
  results travel over a file-based RPC protocol in a per-invocation temp
  directory and never enter the model transcript.

  ## Result channels

  Three shim helpers besides the tool stubs shape what comes back:

    * `text(s)` — the result. Each call atomically flushes a numbered
      `text-<n>.json` block into the rpc dir (write-through, never at exit),
      under a lock, within the `max_text_bytes` budget; the budget charges the
      *encoded frame* — the exact bytes `json.dump` writes, JSON escaping
      included — on BOTH sides of the bridge: the shim charges what it is
      about to write and the host charges the file body it actually reads, so
      an in-budget block is always delivered and nothing the shim refused
      ever fits. The payload is normalized first (lone surrogates become
      U+FFFD), so every frame the shim writes is valid JSON with valid-UTF-8
      text and can never be silently dropped by the host. An over-budget call
      raises `ToolError` and keeps the blocks already flushed. After the run —
      including a timeout/abort kill — the flushed blocks are read in order
      and assembled as the labeled result, with stdout/stderr demoted to a
      clearly labeled diagnostics tail (already capped at `max_output_bytes`).
      This fixes two defects of the stdout-only era: incidental prints and
      library warnings no longer impersonate the answer, and a deliberate
      result now survives the kill that discards half-captured stdout
      mid-line.
    * `notify(msg)` — a fire-and-forget side channel. The RPC pump consumes
      `notify-<n>.json` frames on every sweep and forwards each message to
      the tool's `on_update` callback as a partial update (bounded: 4 KiB per
      message, 64 forwarded messages per run — the count spans sweeps and the
      final drain — silently dropped beyond), so long scripts can surface
      progress without splitting into separate calls. A notify() issued
      immediately before exit is still forwarded: both `serve/2` and the
      persistent stop path drain notifications one final time. Only requests
      are never drained after the run.
    * `batch([(tool, params), ...])` — parallel helper calls. Each element
      runs the plain blocking call inside a bounded thread pool; the pump
      dispatches claimed requests as supervised tasks in waves of
      `max_parallel_rpc` (default 4), so a batch of independent reads really
      does overlap. Claiming — authentication, replay detection, and the call
      budget — stays serialized in the pump, so accounting remains exact under
      concurrency, and a claimed request always ends answered: a killed sweep
      leaves claim evidence (an in-flight marker plus, in session mode, a
      host-side ledger entry the script cannot delete) that a successor sweep
      or the cancel path answers in writing — never re-dispatched. Any
      approval prompt a doomed dispatch left pending is cancelled when the
      dispatch task dies; prompts cannot outlive the script unless tool code
      on the approval path re-enables trap_exit and blocks past its task's
      death (an adversarial-only boundary — see `Rpc`'s moduledoc).

  Backward compatibility is byte-exact: a script that never calls `text()`
  gets the historic stdout-only result, unchanged, in both kernel modes.

  Stderr stays merged into stdout (the `BashExecutor` default) on purpose:
  the port has no separate stderr capture, so un-merging would silently
  *discard* stderr (python tracebacks included) instead of surfacing it in
  the diagnostics tail. Merged, it is visible and labeled.

  ## Shape of a per-call run (default `kernel_mode = "per_call"`)

  1. A temp workspace is created (`0700`) holding `lemon_tools.py` (the
     generated shim, see `CodingAgent.Tools.ExecuteCode.PythonShim`),
     `script.py` (the submitted script with a single import line prepended),
     and an `rpc/` directory.
  2. The script runs through `CodingAgent.BashExecutor` — the same machinery the
     `bash` tool uses — which supplies streaming collection, stdout truncation
     with spill-to-file, abort-signal kill, and the wall-time timeout.
  3. `CodingAgent.Tools.ExecuteCode.Rpc` pumps requests from `rpc/` while the
     script runs, policy-checking and approval-gating every call exactly like a
     direct tool call.
  4. The workspace is removed when the run ends.

  ## Shape of a session run (`kernel_mode = "session"`, opt-in)

  1. The run becomes a *cell* on a persistent interpreter (a kernel) owned by
     `CodingAgent.PythonRepl`: a registry serializes attach/reset and enforces
     live-kernel capacity; a temporary `PythonRepl.Session` worker owns exactly
     one python3 process and serializes cells (one active, bounded FIFO queue).
  2. The kernel is keyed by persisted session id, agent id, canonical cwd,
     canonical interpreter, helper set, and protocol version — never by
     `run_id`, tool-call id, or the caller-overridable session key. Subagents
     isolate through their own persisted session ids.
  3. Each cell gets a fresh bridge: a new `0700` RPC directory and a new
     256-bit token serviced by a temporary
     `CodingAgent.Tools.ExecuteCode.RpcServer`, so helper authority is
     re-established per cell and stale credentials cannot call.
  4. Imports, globals, objects, the module cache, and `os.environ` survive
     across cells — live process memory only, never durable. Ordinary
     exceptions retain that state; an active timeout, cancellation, caller
     death, crash, or protocol fault discards the whole interpreter (partial
     output may be returned with `state_retained: false`). Started code is
     never replayed. `reset: true` replaces the kernel before the script runs.
  5. Session mode may fall back to the isolated per-call path only before code
     starts (missing session scope, unavailable registry, exhausted capacity,
     startup failure); the result reports `persistent: false` and the
     `fallback_reason`. A full queue never falls back.

  ## Danger

  `execute_code` is bash-equivalent: the script runs with host permissions, so
  the RPC allowlist bounds the *Lemon tool* surface, not the OS — python can
  still shell out. It is therefore classified with `bash` in
  `CodingAgent.ToolPolicy` (`@dangerous_tools`, `@minimal_core_tools`), it is
  default-off behind `[runtime.tools.execute_code] enabled`, and it is
  approval-wrappable through the normal registry path. The allowlist is not a
  sandbox.

  ## Deferred

  A real sandbox is follow-up work: a future `sandbox = "wasm"` config value
  would run the script inside the per-session WASM sidecar
  (`CodingAgent.Wasm`), which is a separate tool host with its own protocol and
  would need a python interpreter shipped to WASM — out of scope for v1.
  Likewise docker/ssh placement of the workspace: the `:script_runner` seam and
  the file protocol are designed for it (bind-mount the workspace), but v1 runs
  locally only.
  """

  import Bitwise

  require Logger

  alias CodingAgent.BashExecutor
  alias CodingAgent.PrivateTmp
  alias CodingAgent.PythonRepl
  alias CodingAgent.PythonRepl.{Key, Protocol, Telemetry}
  alias CodingAgent.Tools
  alias CodingAgent.Tools.ExecuteCode.{Config, PythonShim, Rpc, RpcServer}
  alias LemonAgent.AbortSignal
  alias LemonAgent.Security.ExternalContent
  alias LemonAgent.Types.{AgentTool, AgentToolResult}
  alias LemonAi.Types.TextContent

  @min_timeout_ms 1_000
  @poll_interval_ms 25
  @session_config_query_timeout_ms 1_000

  @tool_modules %{
    "read" => Tools.Read,
    "grep" => Tools.Grep,
    "find" => Tools.Find,
    "ls" => Tools.Ls,
    "webfetch" => Tools.WebFetch
  }

  @signatures %{
    "read" => "read(path, offset=None, limit=None)",
    "grep" =>
      "grep(pattern, path=None, glob=None, case_sensitive=None, literal=None, context_lines=None, max_results=None)",
    "find" =>
      "find(pattern, path=None, type=None, max_depth=None, max_results=None, hidden=None)",
    "ls" =>
      "ls(path=None, all=None, long=None, recursive=None, max_depth=None, max_entries=None)",
    "webfetch" => "webfetch(url, extract_mode=None, max_chars=None)"
  }

  @doc """
  Whether `execute_code` is enabled for this working directory.

  The registry calls this to decide whether the tool is disclosed at all — a
  disabled tool must not reach the prompt.
  """
  @spec enabled?(String.t(), keyword()) :: boolean()
  def enabled?(cwd, opts \\ []) do
    Config.load(cwd, Keyword.get(opts, :settings_manager)).enabled
  end

  @doc """
  Returns the execute_code tool definition.
  """
  @spec tool(cwd :: String.t(), opts :: keyword()) :: AgentTool.t()
  def tool(cwd, opts \\ []) do
    config = Config.load(cwd, Keyword.get(opts, :settings_manager))

    %AgentTool{
      name: "execute_code",
      description: description(config),
      label: "Execute Code",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "script" => %{
            "type" => "string",
            "description" =>
              "The python3 script to run. Call text() to append blocks to the tool result; anything the script prints to stdout/stderr is returned only as a labeled diagnostics tail."
          },
          "timeout_ms" => %{
            "type" => "integer",
            "description" =>
              "Optional end-to-end wall-time cap in ms for this run, including session queue wait (clamped to the configured maximum)."
          },
          "reset" => %{
            "type" => "boolean",
            "default" => false,
            "description" =>
              "Optional. Discard any retained interpreter state (imports, globals, objects) before running this script. No effect when every script already runs in a fresh process."
          }
        },
        "required" => ["script"]
      },
      execute: &execute(&1, &2, &3, &4, cwd, opts)
    }
  end

  defp description(%Config{} = config) do
    helpers =
      config.tools
      |> Enum.map(&Map.fetch!(@signatures, &1))
      |> Enum.join(", ")

    helper_sentence =
      if helpers == "" do
        "No agent-tool helper functions are enabled for this workspace, so the script runs standalone."
      else
        "The script can call these pre-imported helper functions, which invoke the corresponding agent tools and return their text output as a string: #{helpers}. Failed calls raise ToolError."
      end

    mode_sentence =
      case config.kernel_mode do
        "session" ->
          "Kernel mode: session — this workspace keeps a persistent python3 interpreter, so imports, globals, and objects survive across calls; pass reset=true to discard retained state before a run."

        "per_call" ->
          "Kernel mode: per_call — each script runs in a fresh python3 process and nothing survives across calls; reset is accepted but has no effect."
      end

    channel_sentence =
      "The script also has text(s), which appends a numbered block to the tool result (its total bytes are capped; blocks are flushed per call, so they survive a timeout), notify(msg), which streams a progress line to the conversation without waiting, and batch([(tool, params), ...]), which runs several helper calls in parallel and returns their results in order."

    result_sentence =
      "Build the answer with text(): only the text() blocks are the result, while everything the script prints to stdout/stderr is appended as a clearly labeled diagnostics tail — a script that never calls text() keeps the historic stdout-only result."

    "Run a python3 script for multi-step exploration. " <>
      mode_sentence <>
      helper_sentence <>
      " " <>
      channel_sentence <>
      " " <>
      result_sentence <>
      " Limits: #{config.timeout_ms} ms wall time, #{config.max_rpc_calls} tool calls with at most #{config.max_parallel_rpc} dispatched in parallel, #{config.max_rpc_result_bytes} total tool-result bytes, text() blocks capped at #{config.max_text_bytes} bytes, stdout capped at #{config.max_output_bytes} bytes." <>
      " The script cannot import lemon internals beyond these helpers; traceback line numbers are offset by 1. Requires python3 on the host."
  end

  @doc """
  Execute a python3 script.

    * `params` - Map containing "script" (required), optional "timeout_ms", and
      optional boolean "reset" (validated; per-call runs treat it as redundant)
    * `signal` - Abort signal reference for cancellation (can be nil)
    * `on_update` - Streaming callback: each `notify()` message the script
      emits is forwarded as a partial `AgentToolResult` (nil consumes and
      drops them instead)
    * `cwd` - Working directory the script runs in
    * `opts` - Tool options (`:settings_manager`, `:tool_policy`,
      `:approval_context`, `:session_id`, `:session_pid`, `:session_module`,
      `:agent_id`, plus the `@doc false` test seams `:python_finder`,
      `:script_runner`, `:execute_code_tool_overrides`, `:python_repl`,
      `:rpc_server`, `:python_repl_registry`, `:clock`, and `:poll`)
  """
  @spec execute(
          tool_call_id :: String.t(),
          params :: map(),
          signal :: reference() | nil,
          on_update :: (AgentToolResult.t() -> :ok) | nil,
          cwd :: String.t(),
          opts :: keyword()
        ) :: AgentToolResult.t() | {:error, term()}
  def execute(_tool_call_id, params, signal, on_update, cwd, opts) do
    if signal && AbortSignal.aborted?(signal) do
      %AgentToolResult{content: [%TextContent{text: "Script cancelled."}]}
    else
      config = invocation_config(cwd, opts)

      with :ok <- check_enabled(config),
           {:ok, script} <- fetch_script(params),
           :ok <- check_reset(params),
           {:ok, python} <- resolve_python(config, opts) do
        case config.kernel_mode do
          "session" -> run_session(script, python, config, params, signal, on_update, cwd, opts)
          "per_call" -> run(script, python, config, params, signal, on_update, cwd, opts)
        end
      end
    end
  end

  defp invocation_config(cwd, opts) do
    configured = Config.load(cwd, Keyword.get(opts, :settings_manager))

    case Keyword.get(opts, :session_pid) do
      session_pid when is_pid(session_pid) ->
        case query_session_config(session_pid, opts) do
          {:ok, %Config{} = effective} ->
            effective

          _unavailable ->
            # A dead, wedged, or incompatible owner cannot authorize retaining
            # an interpreter. Preserve the closure's other validated settings
            # but force the fresh-process path.
            %{configured | kernel_mode: "per_call"}
        end

      _no_session ->
        configured
    end
  end

  defp query_session_config(session_pid, opts) do
    session_module = Keyword.get(opts, :session_module, CodingAgent.Session)

    timeout_ms =
      opts
      |> Keyword.get(:session_config_query_timeout_ms, @session_config_query_timeout_ms)
      |> bounded_session_config_timeout()

    if is_atom(session_module) and Code.ensure_loaded?(session_module) and
         function_exported?(session_module, :execute_code_config, 2) do
      session_module.execute_code_config(session_pid, timeout_ms)
    else
      {:error, :session_unavailable}
    end
  rescue
    _error -> {:error, :session_unavailable}
  catch
    :exit, _reason -> {:error, :session_unavailable}
  end

  defp bounded_session_config_timeout(timeout_ms)
       when is_integer(timeout_ms) and timeout_ms > 0,
       do: min(timeout_ms, @session_config_query_timeout_ms)

  defp bounded_session_config_timeout(_timeout_ms), do: @session_config_query_timeout_ms

  defp check_enabled(%Config{enabled: true}), do: :ok

  defp check_enabled(%Config{}),
    do: {:error, "execute_code is disabled. Enable [runtime.tools.execute_code] in config."}

  defp fetch_script(params) do
    case Map.get(params, "script") do
      script when is_binary(script) and script != "" -> {:ok, script}
      _ -> {:error, "Missing required parameter: script"}
    end
  end

  # `reset` asks for a fresh interpreter in session mode. Per-call runs still
  # validate it and treat it as redundant.
  defp check_reset(params) do
    case Map.get(params, "reset") do
      reset when is_nil(reset) or is_boolean(reset) -> :ok
      _other -> {:error, "reset must be a boolean"}
    end
  end

  # A directory or a non-executable file would reach the shell and come back as
  # a bare exit code 126, so the interpreter is checked here rather than left
  # for `exec` to fail on.
  defp resolve_python(%Config{python_path: path}, _opts) when is_binary(path) do
    case File.stat(path) do
      {:ok, %File.Stat{type: :regular, mode: mode}} when band(mode, 0o111) != 0 ->
        {:ok, path}

      {:ok, %File.Stat{}} ->
        {:error, "configured execute_code python_path is not an executable file: #{path}"}

      {:error, _reason} ->
        {:error, "configured execute_code python_path not found: #{path}"}
    end
  end

  defp resolve_python(%Config{}, opts) do
    finder = Keyword.get(opts, :python_finder, &System.find_executable/1)

    case finder.("python3") do
      python when is_binary(python) and python != "" ->
        {:ok, python}

      _ ->
        {:error,
         "python3 was not found on this host. execute_code requires python3; install it or set [runtime.tools.execute_code] python_path."}
    end
  end

  defp run(script, python, config, params, signal, on_update, cwd, opts) do
    started_at = System.monotonic_time(:microsecond)
    timeout_ms = clamp_timeout(Map.get(params, "timeout_ms"), config)

    case build_workspace(script, config) do
      {:ok, base, rpc_dir, token} ->
        try do
          command = "exec #{shell_escape(python)} #{shell_escape(Path.join(base, "script.py"))}"
          runner = Keyword.get(opts, :script_runner, &BashExecutor.execute/3)

          task =
            Task.Supervisor.async_nolink(CodingAgent.TaskSupervisor, fn ->
              runner.(command, cwd,
                on_chunk: nil,
                signal: signal,
                timeout: timeout_ms,
                max_bytes: config.max_output_bytes
              )
            end)

          ctx = %{
            tools: inner_tools(config, cwd, opts),
            tool_policy: Keyword.get(opts, :tool_policy),
            approval_context: Keyword.get(opts, :approval_context),
            max_calls: config.max_rpc_calls,
            max_result_bytes: config.max_rpc_result_bytes,
            max_parallel_rpc: config.max_parallel_rpc,
            on_update: on_update,
            signal: signal,
            rpc_dir: rpc_dir,
            token: token,
            poll_interval_ms: @poll_interval_ms
          }

          {outcome, task_result, stats} = Rpc.serve(task, ctx)

          # text() blocks are flushed to disk as they are written, so they are
          # already complete on disk whether the script exited normally or was
          # killed by the wall clock/abort; read them while the workspace
          # still exists, before the after-clause tears it down.
          text_blocks = Rpc.read_text_blocks(rpc_dir, max_text_bytes: config.max_text_bytes)

          emit_telemetry(started_at, stats, task_result)
          format(outcome, task_result, stats, signal, timeout_ms, text_blocks)
        after
          bounded_tree_removal(base, "execute_code workspace")
        end

      {:error, reason} ->
        # Unusable mktemp or a rejected/failed reservation: fail closed
        # before any interpreter or script runs.
        {:error, "execute_code could not create its private workspace: #{inspect(reason)}"}
    end
  end

  # Session execution deliberately has a separate entry point from `run/6`.
  # The per-call path remains byte-for-byte compatible for the default mode;
  # this path owns a fresh bridge and re-evaluates all authority for every cell.
  defp run_session(script, python, config, params, signal, on_update, cwd, opts) do
    started_at = clock_now(opts)
    timeout_ms = clamp_timeout(Map.get(params, "timeout_ms"), config)
    deadline_ms = started_at + timeout_ms

    case session_identity(python, config, cwd, opts) do
      {:fallback, reason} ->
        session_fallback(
          script,
          python,
          config,
          params,
          signal,
          on_update,
          cwd,
          opts,
          reason,
          false,
          started_at
        )

      {:error, reason} ->
        session_error(reason, false, false, Rpc.initial_stats(), started_at, opts)

      {:ok, key, owner_pid} ->
        run_session_cell(
          script,
          config,
          params,
          signal,
          on_update,
          cwd,
          opts,
          key,
          owner_pid,
          timeout_ms,
          deadline_ms,
          started_at
        )
    end
  end

  defp session_identity(python, config, cwd, opts) do
    session_id = Keyword.get(opts, :session_id)
    session_pid = Keyword.get(opts, :session_pid)
    agent_id = Keyword.get(opts, :agent_id)

    if valid_session_scope?(session_id, session_pid, agent_id) do
      case Key.new(
             scope_id: session_id,
             agent_id: agent_id,
             cwd: cwd,
             interpreter: python,
             helpers: config.tools,
             protocol_version: Protocol.version()
           ) do
        {:ok, key} -> {:ok, key, session_pid}
        {:error, reason} -> {:error, {:invalid_session_key, reason}}
      end
    else
      {:fallback, :missing_session_scope}
    end
  end

  defp valid_session_scope?(session_id, session_pid, agent_id) do
    is_binary(session_id) and String.trim(session_id) != "" and is_pid(session_pid) and
      is_binary(agent_id) and String.trim(agent_id) != ""
  end

  defp run_session_cell(
         script,
         config,
         params,
         signal,
         on_update,
         cwd,
         opts,
         key,
         owner_pid,
         timeout_ms,
         deadline_ms,
         started_at
       ) do
    repl = Keyword.get(opts, :python_repl, PythonRepl)

    case maybe_reset(repl, key, owner_pid, params, opts) do
      {:ok, reset_performed} ->
        case build_bridge(config) do
          {:ok, base, bridge} ->
            cell_signal = AbortSignal.new()

            case start_rpc_server(bridge, config, cell_signal, on_update, cwd, opts) do
              {:ok, rpc_server} ->
                try do
                  request = %{
                    key: key,
                    owner_pid: owner_pid,
                    code: PythonShim.render_script(script, config.tools),
                    cwd: cwd,
                    bridge: bridge,
                    timeout_ms: timeout_ms,
                    max_live_kernels: config.max_live_kernels,
                    kernel_idle_timeout_ms: config.kernel_idle_timeout_ms,
                    max_queued_cells: config.max_queued_cells_per_kernel,
                    max_output_bytes: config.max_output_bytes,
                    helper_source: PythonShim.render_module(config.tools, config.max_text_bytes)
                  }

                  request =
                    case Keyword.fetch(opts, :python_repl_registry) do
                      {:ok, registry} -> Map.put(request, :registry, registry)
                      :error -> request
                    end

                  owner = self()

                  task =
                    Task.Supervisor.async(CodingAgent.TaskSupervisor, fn ->
                      repl.execute(request)
                    end)

                  owner_guard = monitor_task_owner(owner, task.pid, base)

                  try do
                    rpc_server_module = Keyword.get(opts, :rpc_server, RpcServer)

                    result =
                      await_session_task(
                        task,
                        signal,
                        cell_signal,
                        rpc_server_module,
                        rpc_server,
                        deadline_ms,
                        opts
                      )

                    stats = rpc_final_stats(rpc_server_module, rpc_server)

                    # Same write-through guarantee as the per-call path: read
                    # whatever the cell flushed before it ended — including a
                    # timeout or abort kill — while the bridge still exists.
                    text_blocks =
                      Rpc.read_text_blocks(bridge.dir, max_text_bytes: config.max_text_bytes)

                    case format_session_result(
                           result,
                           stats,
                           signal,
                           timeout_ms,
                           reset_performed,
                           started_at,
                           opts,
                           text_blocks
                         ) do
                      {:prestart_fallback, reason} ->
                        session_fallback(
                          script,
                          nil,
                          config,
                          params,
                          signal,
                          on_update,
                          cwd,
                          opts,
                          reason,
                          reset_performed,
                          started_at
                        )

                      tool_result ->
                        tool_result
                    end
                  after
                    stop_owner_guard(owner_guard)
                  end
                after
                  try do
                    _ = stop_rpc_server(Keyword.get(opts, :rpc_server, RpcServer), rpc_server)
                  after
                    bounded_tree_removal(base, "execute_code cell bridge")
                  end
                end

              {:error, reason} ->
                # Best-effort teardown of the cell bridge we reserved; the
                # error below is the cell's verdict, and PrivateTmp's root
                # cleanup owns any residue.
                _ = File.rm_rf(base)

                session_error(
                  reason,
                  false,
                  reset_performed,
                  Rpc.initial_stats(),
                  started_at,
                  opts
                )
            end

          {:error, reason} ->
            session_error(reason, false, reset_performed, Rpc.initial_stats(), started_at, opts)
        end

      {:fallback, reason, reset_performed} ->
        session_fallback(
          script,
          nil,
          config,
          params,
          signal,
          on_update,
          cwd,
          opts,
          reason,
          reset_performed,
          started_at
        )

      {:error, reason} ->
        session_error(reason, false, false, Rpc.initial_stats(), started_at, opts)
    end
  end

  defp maybe_reset(repl, key, owner_pid, params, opts) do
    if Map.get(params, "reset") == true do
      reset_opts =
        case Keyword.fetch(opts, :python_repl_registry) do
          {:ok, registry} -> [registry: registry]
          :error -> []
        end

      case repl.reset(key, owner_pid, reset_opts) do
        {:ok, %{reset_performed: performed}} when is_boolean(performed) ->
          {:ok, performed}

        {:ok, _} ->
          {:ok, true}

        {:error, %{reason: reason} = result}
        when reason in [:registry_unavailable, :stop_failed] ->
          {:fallback, reason, Map.get(result, :reset_performed, false)}

        {:error, reason} when reason in [:registry_unavailable, :stop_failed] ->
          {:fallback, reason, false}

        {:error, %{reason: reason}} ->
          {:error, {:reset_failed, reason}}

        {:error, reason} ->
          {:error, {:reset_failed, reason}}

        other ->
          {:error, {:reset_failed, other}}
      end
    else
      {:ok, false}
    end
  end

  defp build_bridge(config) do
    token = :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)

    case private_base("lemon-exec-code-cell", fn base ->
           with {:ok, rpc_dir} <- PrivateTmp.reserve_dir(base, "rpc") do
             # The budget rides with the bridge: every persistent cell gets a
             # fresh text() allowance, installed by the shim's per-cell
             # `_configure` reset.
             {:ok, %{dir: rpc_dir, token: token, max_text_bytes: config.max_text_bytes}}
           end
         end) do
      {:ok, base, bridge} -> {:ok, base, bridge}
      {:error, reason} -> {:error, {:bridge_setup_failed, reason}}
    end
  end

  defp start_rpc_server(bridge, config, signal, on_update, cwd, opts) do
    rpc_server = Keyword.get(opts, :rpc_server, RpcServer)

    ctx = %{
      tools: inner_tools(config, cwd, opts),
      tool_policy: Keyword.get(opts, :tool_policy),
      approval_context: Keyword.get(opts, :approval_context),
      max_calls: config.max_rpc_calls,
      max_result_bytes: config.max_rpc_result_bytes,
      max_parallel_rpc: config.max_parallel_rpc,
      on_update: on_update,
      signal: signal,
      rpc_dir: bridge.dir,
      token: bridge.token,
      poll_interval_ms: @poll_interval_ms,
      persistent_repl?: true
    }

    case rpc_server.start_link(ctx) do
      {:ok, server} -> {:ok, server}
      {:error, reason} -> {:error, {:rpc_start_failed, reason}}
      other -> {:error, {:rpc_start_failed, other}}
    end
  end

  # The facade task is the `GenServer.call` caller from PythonRepl's point of
  # view. A linked task plus its explicit owner guard makes caller death
  # discard the active cell even when Task.Supervisor link semantics do not
  # propagate that death. The separate cell signal belongs only to this bridge:
  # it is aborted before formatting so an RPC approval or tool cannot outlive
  # the cell.
  defp await_session_task(task, signal, cell_signal, rpc_server, server, deadline_ms, opts) do
    poll_interval_ms = Keyword.get(opts, :persistent_poll_interval_ms, @poll_interval_ms)

    if aborted?(signal, opts) do
      abort_cell(cell_signal, rpc_server, server)
      _ = Task.shutdown(task, :brutal_kill)
      :aborted
    else
      remaining_ms = deadline_ms - clock_now(opts)

      if remaining_ms <= 0 do
        abort_cell(cell_signal, rpc_server, server)
        _ = Task.shutdown(task, :brutal_kill)
        :timed_out
      else
        case Task.yield(task, min(poll_interval_ms, remaining_ms)) do
          {:ok, result} ->
            abort_cell(cell_signal, rpc_server, server)
            {:completed, result}

          {:exit, reason} ->
            abort_cell(cell_signal, rpc_server, server)
            {:task_exit, reason}

          nil ->
            if aborted?(signal, opts) do
              abort_cell(cell_signal, rpc_server, server)
              _ = Task.shutdown(task, :brutal_kill)
              :aborted
            else
              await_session_task(
                task,
                signal,
                cell_signal,
                rpc_server,
                server,
                deadline_ms,
                opts
              )
            end
        end
      end
    end
  end

  defp monitor_task_owner(owner, task_pid, base) do
    spawn(fn ->
      monitor = Process.monitor(owner)

      receive do
        {:DOWN, ^monitor, :process, ^owner, _reason} ->
          terminate_facade_task(task_pid)
          bounded_tree_removal(base, "execute_code cell bridge")

        :stop ->
          Process.demonitor(monitor, [:flush])
      end
    end)
  end

  defp terminate_facade_task(task_pid) do
    _ = Task.Supervisor.terminate_child(CodingAgent.TaskSupervisor, task_pid)
    :ok
  catch
    :exit, _ -> :ok
  end

  # Workspace/bridge teardown must stay bounded: the script that ran inside
  # could have planted an arbitrarily large tree, and File.rm_rf/1 would
  # enumerate and delete without limit. Leftovers stay owner-only inside the
  # private root and are candidates for the boot-time stale-root sweep.
  defp bounded_tree_removal(base, label) do
    case PrivateTmp.remove_tree(base) do
      :complete ->
        :ok

      :truncated ->
        Logger.warning(
          "#{label} teardown hit the entry limit; remainder left under the private root"
        )

        :ok
    end
  end

  defp stop_owner_guard(owner_guard), do: send(owner_guard, :stop)

  defp abort_cell(cell_signal, rpc_server, server) do
    :ok = AbortSignal.abort(cell_signal)
    _ = abort_rpc_server(rpc_server, server)
    :ok
  end

  defp abort_rpc_server(rpc_server, server) do
    rpc_server.abort(server)
  catch
    :exit, _ -> :ok
  end

  defp aborted?(nil, _opts), do: false

  defp aborted?(signal, opts) do
    case Keyword.get(opts, :poll) do
      nil -> AbortSignal.aborted?(signal)
      poll when is_function(poll, 1) -> poll.(signal)
      poll -> poll.aborted?(signal)
    end
  end

  # Drain-then-read: the cell's stop-time notify() frames must land in the
  # stats this cell reports. A plain stats read here would miss everything
  # the server's final drain forwards — its counts only reach state that
  # dies with terminate/2 — so the teardown read runs the drain itself and
  # returns the merged stats (terminate/2 keeps its own drain purely as a
  # backstop).
  defp rpc_final_stats(rpc_server, server) do
    rpc_server.drain_and_stats(server)
  catch
    :exit, _ -> Rpc.initial_stats()
  end

  defp stop_rpc_server(rpc_server, server) do
    rpc_server.stop(server)
  catch
    :exit, _ -> :ok
  end

  defp format_session_result(
         :timed_out,
         stats,
         signal,
         timeout_ms,
         reset_performed,
         started_at,
         opts,
         text_blocks
       ) do
    result = %{reason: :timeout, state_retained: false, kernel_reused: false}

    session_tool_result(
      session_text(result, {:error, signal, timeout_ms}, text_blocks),
      result,
      stats,
      reset_performed,
      started_at,
      opts
    )
  end

  defp format_session_result(
         :aborted,
         stats,
         _signal,
         _timeout_ms,
         reset_performed,
         started_at,
         opts,
         text_blocks
       ) do
    session_tool_result(
      assemble_channel_text("Script cancelled.", text_blocks, "", false, nil),
      %{reason: :cancelled, state_retained: false, kernel_reused: false},
      stats,
      reset_performed,
      started_at,
      opts
    )
  end

  defp format_session_result(
         {:task_exit, reason},
         stats,
         _signal,
         _timeout_ms,
         reset_performed,
         started_at,
         opts,
         _text_blocks
       ) do
    session_tool_result(
      "execute_code session task exited: #{inspect(reason)}",
      %{reason: :task_exit, state_retained: false, kernel_reused: false},
      stats,
      reset_performed,
      started_at,
      opts
    )
  end

  defp format_session_result(
         {:completed, {:ok, result}},
         stats,
         _signal,
         _timeout_ms,
         reset_performed,
         started_at,
         opts,
         text_blocks
       )
       when is_map(result) do
    session_tool_result(
      session_text(result, :ok, text_blocks),
      result,
      stats,
      reset_performed,
      started_at,
      opts
    )
  end

  defp format_session_result(
         {:completed, {:error, %{reason: reason} = _result}},
         stats,
         signal,
         timeout_ms,
         reset_performed,
         started_at,
         _opts,
         _text_blocks
       )
       when reason in [:capacity_exhausted, :registry_unavailable, :startup_failed] do
    # These are the only façade failures known to occur before a cell starts.
    # A Session result such as :worker_exit or :queue_full is intentionally not
    # retried in a fresh interpreter, and a cell that never started cannot have
    # flushed text blocks.
    _ = {stats, signal, timeout_ms, reset_performed, started_at}
    {:prestart_fallback, reason}
  end

  defp format_session_result(
         {:completed, {:error, result}},
         stats,
         signal,
         timeout_ms,
         reset_performed,
         started_at,
         opts,
         text_blocks
       )
       when is_map(result) do
    session_tool_result(
      session_text(result, {:error, signal, timeout_ms}, text_blocks),
      result,
      stats,
      reset_performed,
      started_at,
      opts
    )
  end

  defp format_session_result(
         {:completed, other},
         stats,
         _signal,
         _timeout_ms,
         reset_performed,
         started_at,
         opts,
         _text_blocks
       ) do
    session_tool_result(
      "execute_code session returned an invalid result: #{inspect(other)}",
      %{reason: :invalid_result, state_retained: false, kernel_reused: false},
      stats,
      reset_performed,
      started_at,
      opts
    )
  end

  # A script that never called text() keeps its exact pre-channel transcript
  # shape (byte-for-byte), so existing prompts and caches are unaffected.
  defp session_text(result, :ok, []) do
    case Map.get(result, :output, "") do
      "" -> "(script produced no output)"
      output -> maybe_full_output(output, result)
    end
  end

  defp session_text(result, {:error, signal, timeout_ms}, []) do
    output = Map.get(result, :output, "")
    headline = session_error_headline(result, signal, timeout_ms)

    if output == "", do: headline, else: "#{headline}\n\n#{maybe_full_output(output, result)}"
  end

  defp session_text(result, :ok, text_blocks) do
    assemble_channel_text(
      nil,
      text_blocks,
      Map.get(result, :output, ""),
      Map.get(result, :truncated, false),
      Map.get(result, :full_output_path)
    )
  end

  defp session_text(result, {:error, signal, timeout_ms}, text_blocks) do
    assemble_channel_text(
      session_error_headline(result, signal, timeout_ms),
      text_blocks,
      Map.get(result, :output, ""),
      Map.get(result, :truncated, false),
      Map.get(result, :full_output_path)
    )
  end

  defp session_error_headline(result, signal, timeout_ms) do
    case Map.get(result, :reason) do
      :timeout ->
        "Script timed out after #{timeout_ms}ms."

      :cancelled ->
        if(signal && AbortSignal.aborted?(signal),
          do: "Script cancelled.",
          else: "Script cancelled."
        )

      :exception ->
        exception_headline(Map.get(result, :exception))

      reason ->
        "execute_code session failed: #{inspect(reason)}"
    end
  end

  defp exception_headline(%{name: name, message: message})
       when is_binary(name) and is_binary(message),
       do: "Script raised #{name}: #{message}"

  defp exception_headline(_), do: "Script raised an exception."

  defp maybe_full_output(output, %{truncated: true, full_output_path: path}) when is_binary(path),
    do: "#{output}\n\n[Full output saved to: #{path}]"

  defp maybe_full_output(output, _result), do: output

  defp session_tool_result(text, result, stats, reset_performed, started_at, opts) do
    # Trust must never flip to trusted through LOST accounting: when a sweep
    # settles without a trustworthy stats return — a brutal kill (abort/stop),
    # an abnormal exit, or a contained fault — tools_used is a lower bound
    # (executed work may be missing from it), so the cell falls back to
    # :untrusted — the conservative side — instead of trusting by absence of
    # evidence.
    untrusted? =
      Map.get(stats, :accounting_loss) == true or
        MapSet.member?(stats.tools_used, "webfetch")

    %AgentToolResult{
      content: [
        %TextContent{
          text:
            if(untrusted?,
              do: ExternalContent.wrap_web_content(text, :web_fetch),
              else: text
            )
        }
      ],
      details:
        session_details(
          result,
          stats,
          reset_performed,
          clock_now(opts) - started_at
        ),
      trust: if(untrusted?, do: :untrusted, else: :trusted)
    }
  end

  defp session_details(result, stats, reset_performed, duration_ms) do
    %{
      persistent: true,
      kernel_reused: Map.get(result, :kernel_reused, false),
      reset_performed: reset_performed,
      state_retained: Map.get(result, :state_retained, false),
      duration_ms: max(duration_ms, 0),
      exit_code: Map.get(result, :exit_status),
      truncated: Map.get(result, :truncated, false),
      rpc_calls: stats.calls,
      rpc_denied: stats.denied,
      rpc_errors: stats.errors,
      rpc_bytes: stats.bytes,
      rpc_tools: stats.tools_used |> MapSet.to_list() |> Enum.sort()
    }
    |> maybe_put(:full_output_path, Map.get(result, :full_output_path))
    |> maybe_put(:reason, Map.get(result, :reason))
    # True when the RpcServer settled a sweep without a trustworthy stats
    # return — a brutal kill (abort/stop), an abnormal exit, or a contained
    # fault: the rpc_* numbers above are then a lower bound (see
    # session_tool_result's trust rule).
    |> maybe_put(:rpc_accounting_loss, Map.get(stats, :accounting_loss))
  end

  defp session_fallback(
         script,
         python,
         config,
         params,
         signal,
         on_update,
         cwd,
         opts,
         reason,
         reset_performed,
         started_at
       ) do
    Telemetry.fallback(reason)
    # `python` is resolved before this path. A missing scope occurs after
    # resolution, while facade admission failures reach this helper with nil.
    python = python || resolve_fallback_python(config, opts)
    result = run(script, python, config, params, signal, on_update, cwd, opts)

    case result do
      %AgentToolResult{} = tool_result ->
        details =
          Map.merge(tool_result.details || %{}, %{
            persistent: false,
            kernel_reused: false,
            reset_performed: reset_performed,
            state_retained: false,
            fallback_reason: reason,
            duration_ms: max(clock_now(opts) - started_at, 0)
          })

        %{tool_result | details: details}

      other ->
        other
    end
  end

  defp resolve_fallback_python(config, opts) do
    case resolve_python(config, opts) do
      {:ok, python} -> python
      {:error, reason} -> raise "unreachable session fallback without python: #{inspect(reason)}"
    end
  end

  defp session_error(reason, state_retained, reset_performed, stats, started_at, opts) do
    session_tool_result(
      "execute_code session failed: #{inspect(reason)}",
      %{reason: reason, state_retained: state_retained, kernel_reused: false},
      stats,
      reset_performed,
      started_at,
      opts
    )
  end

  defp clock_now(opts) do
    case Keyword.get(opts, :clock) do
      nil -> System.monotonic_time(:millisecond)
      clock when is_function(clock, 0) -> clock.()
      clock -> clock.monotonic_time(:millisecond)
    end
  end

  defp maybe_put(details, _key, nil), do: details
  defp maybe_put(details, key, value), do: Map.put(details, key, value)

  defp clamp_timeout(value, %Config{timeout_ms: max_ms}) when is_integer(value),
    do: max(@min_timeout_ms, min(value, max_ms))

  defp clamp_timeout(_value, %Config{timeout_ms: max_ms}), do: max_ms

  # The whole workspace is assembled through `PrivateTmp`: the base and rpc
  # directories are reserved atomically at 0700 and both staged files are
  # reserved at 0600 and published by same-directory rename, so no object is
  # ever observable with umask-derived permissions and no chmod window
  # exists. A failure after the base was reserved removes exactly that base.
  defp build_workspace(script, %Config{} = config) do
    token = :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)

    case private_base("lemon-exec-code", &stage_workspace(script, config, token, &1)) do
      {:ok, base, rpc_dir} -> {:ok, base, rpc_dir, token}
      {:error, reason} -> {:error, {:workspace_setup_failed, reason}}
    end
  end

  defp stage_workspace(script, config, token, base) do
    with {:ok, rpc_dir} <- PrivateTmp.reserve_dir(base, "rpc"),
         :ok <-
           PrivateTmp.write_file(
             base,
             "lemon_tools.py",
             PythonShim.render_prelude(rpc_dir, token, config.tools, config.max_text_bytes)
           ),
         :ok <-
           PrivateTmp.write_file(
             base,
             "script.py",
             PythonShim.render_script(script, config.tools)
           ) do
      {:ok, rpc_dir}
    end
  end

  # Reserves a one-owner base directory and hands it to `builder`. If
  # anything inside fails, only the base this call reserved is removed; a
  # reservation that mktemp never confirmed is never deleted speculatively.
  defp private_base(prefix, builder) do
    with {:ok, root} <- PrivateTmp.root(),
         {:ok, base} <- PrivateTmp.reserve_dir(root, prefix) do
      case builder.(base) do
        {:ok, value} ->
          {:ok, base, value}

        {:error, reason} ->
          # Best-effort removal of exactly the base this call reserved; a
          # reservation mktemp never confirmed is never deleted speculatively.
          _ = File.rm_rf(base)
          {:error, reason}
      end
    end
  end

  # The pump applies policy and approval per call, so the inner tools stay
  # unwrapped here — wrapping them twice would double-prompt the user.
  defp inner_tools(%Config{tools: names}, cwd, opts) do
    overrides = Keyword.get(opts, :execute_code_tool_overrides, %{})

    Map.new(names, fn name ->
      tool = Map.get(overrides, name) || Map.fetch!(@tool_modules, name).tool(cwd, opts)
      {name, tool}
    end)
  end

  defp shell_escape(path) do
    "'" <> String.replace(path, "'", "'\"'\"'") <> "'"
  end

  defp format(:exit, reason, _stats, _signal, _timeout_ms, _text_blocks),
    do: {:error, "execute_code runner crashed: #{inspect(reason)}"}

  defp format(:ok, {:error, reason}, _stats, _signal, _timeout_ms, _text_blocks),
    do: {:error, "Error executing script: #{inspect(reason)}"}

  defp format(
         :ok,
         {:ok, %BashExecutor.Result{} = result},
         stats,
         signal,
         timeout_ms,
         text_blocks
       ) do
    text = result_text(result, signal, timeout_ms, text_blocks)
    used_webfetch? = MapSet.member?(stats.tools_used, "webfetch")

    %AgentToolResult{
      content: [
        %TextContent{
          text:
            if(used_webfetch?, do: ExternalContent.wrap_web_content(text, :web_fetch), else: text)
        }
      ],
      details: build_details(result, stats),
      trust: if(used_webfetch?, do: :untrusted, else: :trusted)
    }
  end

  defp format(:ok, other, _stats, _signal, _timeout_ms, _text_blocks),
    do: {:error, "Error executing script: #{inspect(other)}"}

  # A run without text() blocks keeps its exact pre-channel shape: cancelled
  # and timeout headlines, truncation spill markers, exit-code lines, and the
  # "(script produced no output)" teaching line all stay byte-identical.
  defp result_text(%BashExecutor.Result{cancelled: true} = result, signal, timeout_ms, []) do
    headline =
      if signal && AbortSignal.aborted?(signal) do
        "Script cancelled."
      else
        "Script timed out after #{timeout_ms}ms."
      end

    case result.output do
      output when is_binary(output) and output != "" -> "#{headline}\n\n#{output}"
      _ -> headline
    end
  end

  defp result_text(%BashExecutor.Result{exit_code: 0} = result, _signal, _timeout_ms, []) do
    output = result.output || ""

    cond do
      result.truncated && result.full_output_path ->
        "#{output}\n\n[Full output saved to: #{result.full_output_path}]"

      output == "" ->
        "(script produced no output)"

      true ->
        output
    end
  end

  defp result_text(%BashExecutor.Result{} = result, _signal, _timeout_ms, []) do
    output = result.output || ""

    cond do
      result.truncated && result.full_output_path ->
        "#{output}\n\n[Full output saved to: #{result.full_output_path}]\n\nScript exited with code #{result.exit_code}"

      output != "" ->
        "#{output}\n\nScript exited with code #{result.exit_code}"

      true ->
        "Script exited with code #{result.exit_code}"
    end
  end

  # Result-channel assembly, used whenever the script called text() at least
  # once: headline -> the text() blocks verbatim in flush order, labeled as
  # the script's result -> a clearly labeled diagnostics tail. The tail is
  # stdout/stderr as captured — already capped at `max_output_bytes` by
  # BashExecutor per-call (stderr is deliberately still merged into stdout,
  # because stopping the merge would discard stderr entirely rather than
  # surface it here) and by the PythonRepl cell pipeline in session mode. A
  # killed run still shows its flushed blocks; only the partial stdout of the
  # kill is diagnostic. The exit-code line moves into the headline slot so
  # the deliberate result, not incidental output, closes the message.
  defp result_text(%BashExecutor.Result{cancelled: true} = result, signal, timeout_ms, blocks) do
    headline =
      if signal && AbortSignal.aborted?(signal) do
        "Script cancelled."
      else
        "Script timed out after #{timeout_ms}ms."
      end

    assemble_channel_text(
      headline,
      blocks,
      result.output || "",
      result.truncated,
      result.full_output_path
    )
  end

  defp result_text(%BashExecutor.Result{exit_code: 0} = result, _signal, _timeout_ms, blocks) do
    assemble_channel_text(
      nil,
      blocks,
      result.output || "",
      result.truncated,
      result.full_output_path
    )
  end

  defp result_text(%BashExecutor.Result{} = result, _signal, _timeout_ms, blocks) do
    assemble_channel_text(
      "Script exited with code #{result.exit_code}",
      blocks,
      result.output || "",
      result.truncated,
      result.full_output_path
    )
  end

  defp assemble_channel_text(headline, [], _output, _truncated, _full_output_path), do: headline

  defp assemble_channel_text(headline, blocks, output, truncated, full_output_path)
       when is_list(blocks) and blocks != [] do
    body =
      if output == "" do
        "(script produced no output)"
      else
        output
      end

    body =
      if truncated && full_output_path do
        "#{body}\n\n[Full output saved to: #{full_output_path}]"
      else
        body
      end

    [
      headline,
      "Script result (text()):\n" <> Enum.join(blocks, "\n"),
      "Diagnostics (stdout/stderr, not the result):\n" <> body
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n\n")
  end

  defp build_details(%BashExecutor.Result{} = result, stats) do
    details = %{
      exit_code: result.exit_code,
      truncated: result.truncated,
      rpc_calls: stats.calls,
      rpc_denied: stats.denied,
      rpc_errors: stats.errors,
      rpc_bytes: stats.bytes,
      rpc_tools: stats.tools_used |> MapSet.to_list() |> Enum.sort()
    }

    if result.full_output_path do
      Map.put(details, :full_output_path, result.full_output_path)
    else
      details
    end
  end

  defp emit_telemetry(started_at, stats, task_result) do
    exit_code =
      case task_result do
        {:ok, %BashExecutor.Result{exit_code: code}} -> code
        _ -> nil
      end

    LemonCore.Telemetry.emit(
      [:coding_agent, :execute_code, :stop],
      %{duration_us: System.monotonic_time(:microsecond) - started_at, count: 1},
      %{rpc_calls: stats.calls, rpc_denied: stats.denied, exit_code: exit_code}
    )
  end
end
