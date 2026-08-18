defmodule CodingAgent.Tools.ExecuteCode do
  @moduledoc """
  Programmatic tool calling: the model submits a python3 script, the script
  calls agent tools through pre-imported helper functions, and only what the
  script prints comes back as the tool result.

  This is the context lever. A script can read fifty files, grep a whole tree,
  or fetch a page and then print a three-line summary; the intermediate tool
  results travel over a file-based RPC protocol in a per-invocation temp
  directory and never enter the model transcript.

  ## Shape of a run

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

  alias CodingAgent.BashExecutor
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
              "The python3 script to run. Its stdout (and stderr) is the tool result."
          },
          "timeout_ms" => %{
            "type" => "integer",
            "description" =>
              "Optional wall-time cap in ms for this run (clamped to the configured maximum)."
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

    "Run a python3 script for multi-step exploration. " <>
      mode_sentence <>
      helper_sentence <>
      " Intermediate results stay out of the conversation — only what the script prints to stdout is returned, so filter and aggregate in the script and print a compact final answer." <>
      " Limits: #{config.timeout_ms} ms wall time, #{config.max_rpc_calls} tool calls, #{config.max_rpc_result_bytes} total tool-result bytes, stdout capped at #{config.max_output_bytes} bytes." <>
      " The script cannot import lemon internals beyond these helpers; traceback line numbers are offset by 1. Requires python3 on the host."
  end

  @doc """
  Execute a python3 script.

  ## Parameters

    * `params` - Map containing "script" (required), optional "timeout_ms", and
      optional boolean "reset" (validated; per-call runs treat it as redundant)
    * `signal` - Abort signal reference for cancellation (can be nil)
    * `on_update` - Streaming callback (unused: script output is not streamed)
    * `cwd` - Working directory the script runs in
    * `opts` - Tool options (`:settings_manager`, `:tool_policy`,
      `:approval_context`, `:session_id`, `:session_pid`, `:agent_id`, plus
      the `@doc false` test seams `:python_finder`, `:script_runner`,
      `:execute_code_tool_overrides`, `:python_repl`, `:rpc_server`,
      `:python_repl_registry`, `:clock`, and `:poll`)
  """
  @spec execute(
          tool_call_id :: String.t(),
          params :: map(),
          signal :: reference() | nil,
          on_update :: (AgentToolResult.t() -> :ok) | nil,
          cwd :: String.t(),
          opts :: keyword()
        ) :: AgentToolResult.t() | {:error, term()}
  def execute(_tool_call_id, params, signal, _on_update, cwd, opts) do
    if signal && AbortSignal.aborted?(signal) do
      %AgentToolResult{content: [%TextContent{text: "Script cancelled."}]}
    else
      config = Config.load(cwd, Keyword.get(opts, :settings_manager))

      with :ok <- check_enabled(config),
           {:ok, script} <- fetch_script(params),
           :ok <- check_reset(params),
           {:ok, python} <- resolve_python(config, opts) do
        case config.kernel_mode do
          "session" -> run_session(script, python, config, params, signal, cwd, opts)
          "per_call" -> run(script, python, config, params, signal, cwd, opts)
        end
      end
    end
  end

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

  defp run(script, python, config, params, signal, cwd, opts) do
    started_at = System.monotonic_time(:microsecond)
    timeout_ms = clamp_timeout(Map.get(params, "timeout_ms"), config)
    {base, rpc_dir, token} = build_workspace(script, config)

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
        signal: signal,
        rpc_dir: rpc_dir,
        token: token,
        poll_interval_ms: @poll_interval_ms
      }

      {outcome, task_result, stats} = Rpc.serve(task, ctx)

      emit_telemetry(started_at, stats, task_result)
      format(outcome, task_result, stats, signal, timeout_ms)
    after
      File.rm_rf(base)
    end
  end

  # Session execution deliberately has a separate entry point from `run/6`.
  # The per-call path remains byte-for-byte compatible for the default mode;
  # this path owns a fresh bridge and re-evaluates all authority for every cell.
  defp run_session(script, python, config, params, signal, cwd, opts) do
    started_at = clock_now(opts)
    timeout_ms = clamp_timeout(Map.get(params, "timeout_ms"), config)

    case session_identity(python, config, cwd, opts) do
      {:fallback, reason} ->
        session_fallback(
          script,
          python,
          config,
          params,
          signal,
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
          cwd,
          opts,
          key,
          owner_pid,
          timeout_ms,
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
         cwd,
         opts,
         key,
         owner_pid,
         timeout_ms,
         started_at
       ) do
    repl = Keyword.get(opts, :python_repl, PythonRepl)

    with {:ok, reset_performed} <- maybe_reset(repl, key, owner_pid, params, opts) do
      case build_bridge() do
        {:ok, base, bridge} ->
          cell_signal = AbortSignal.new()

          case start_rpc_server(bridge, config, cell_signal, cwd, opts) do
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
                  helper_source: PythonShim.render_module(config.tools)
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
                      opts
                    )

                  stats = rpc_stats(rpc_server_module, rpc_server)

                  case format_session_result(
                         result,
                         stats,
                         signal,
                         timeout_ms,
                         reset_performed,
                         started_at,
                         opts
                       ) do
                    {:prestart_fallback, reason} ->
                      session_fallback(
                        script,
                        nil,
                        config,
                        params,
                        signal,
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
                  File.rm_rf(base)
                end
              end

            {:error, reason} ->
              File.rm_rf(base)
              session_error(reason, false, reset_performed, Rpc.initial_stats(), started_at, opts)
          end

        {:error, reason} ->
          session_error(reason, false, reset_performed, Rpc.initial_stats(), started_at, opts)
      end
    else
      {:fallback, reason, reset_performed} ->
        session_fallback(
          script,
          nil,
          config,
          params,
          signal,
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

  defp build_bridge do
    suffix = :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
    base = Path.join(System.tmp_dir!(), "lemon-exec-code-cell-" <> suffix)
    rpc_dir = Path.join(base, "rpc")
    token = :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)

    try do
      :ok = File.mkdir(base)
      :ok = File.chmod(base, 0o700)
      :ok = File.mkdir(rpc_dir)
      :ok = File.chmod(rpc_dir, 0o700)
      {:ok, base, %{dir: rpc_dir, token: token}}
    rescue
      error ->
        File.rm_rf(base)
        {:error, {:bridge_setup_failed, error.__struct__}}
    end
  end

  defp start_rpc_server(bridge, config, signal, cwd, opts) do
    rpc_server = Keyword.get(opts, :rpc_server, RpcServer)

    ctx = %{
      tools: inner_tools(config, cwd, opts),
      tool_policy: Keyword.get(opts, :tool_policy),
      approval_context: Keyword.get(opts, :approval_context),
      max_calls: config.max_rpc_calls,
      max_result_bytes: config.max_rpc_result_bytes,
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
  defp await_session_task(task, signal, cell_signal, rpc_server, server, opts) do
    poll_interval_ms = Keyword.get(opts, :persistent_poll_interval_ms, @poll_interval_ms)

    case Task.yield(task, poll_interval_ms) do
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
          await_session_task(task, signal, cell_signal, rpc_server, server, opts)
        end
    end
  end

  defp monitor_task_owner(owner, task_pid, base) do
    spawn(fn ->
      monitor = Process.monitor(owner)

      receive do
        {:DOWN, ^monitor, :process, ^owner, _reason} ->
          terminate_facade_task(task_pid)
          File.rm_rf(base)

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

  defp rpc_stats(rpc_server, server) do
    rpc_server.stats(server)
  catch
    :exit, _ -> Rpc.initial_stats()
  end

  defp stop_rpc_server(rpc_server, server) do
    rpc_server.stop(server)
  catch
    :exit, _ -> :ok
  end

  defp format_session_result(
         :aborted,
         stats,
         _signal,
         _timeout_ms,
         reset_performed,
         started_at,
         opts
       ) do
    session_tool_result(
      "Script cancelled.",
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
         opts
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
         opts
       )
       when is_map(result) do
    session_tool_result(
      session_text(result, :ok),
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
         _opts
       )
       when reason in [:capacity_exhausted, :registry_unavailable, :startup_failed] do
    # These are the only façade failures known to occur before a cell starts.
    # A Session result such as :worker_exit or :queue_full is intentionally not
    # retried in a fresh interpreter.
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
         opts
       )
       when is_map(result) do
    session_tool_result(
      session_text(result, {:error, signal, timeout_ms}),
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
         opts
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

  defp session_text(result, :ok) do
    case Map.get(result, :output, "") do
      "" -> "(script produced no output)"
      output -> maybe_full_output(output, result)
    end
  end

  defp session_text(result, {:error, signal, timeout_ms}) do
    output = Map.get(result, :output, "")

    headline =
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

    if output == "", do: headline, else: "#{headline}\n\n#{maybe_full_output(output, result)}"
  end

  defp exception_headline(%{name: name, message: message})
       when is_binary(name) and is_binary(message),
       do: "Script raised #{name}: #{message}"

  defp exception_headline(_), do: "Script raised an exception."

  defp maybe_full_output(output, %{truncated: true, full_output_path: path}) when is_binary(path),
    do: "#{output}\n\n[Full output saved to: #{path}]"

  defp maybe_full_output(output, _result), do: output

  defp session_tool_result(text, result, stats, reset_performed, started_at, opts) do
    used_webfetch? = MapSet.member?(stats.tools_used, "webfetch")

    %AgentToolResult{
      content: [
        %TextContent{
          text:
            if(used_webfetch?, do: ExternalContent.wrap_web_content(text, :web_fetch), else: text)
        }
      ],
      details:
        session_details(
          result,
          stats,
          reset_performed,
          clock_now(opts) - started_at
        ),
      trust: if(used_webfetch?, do: :untrusted, else: :trusted)
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
  end

  defp session_fallback(
         script,
         python,
         config,
         params,
         signal,
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
    result = run(script, python, config, params, signal, cwd, opts)

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

  defp build_workspace(script, %Config{} = config) do
    suffix = :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
    token = :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)
    base = Path.join(System.tmp_dir!(), "lemon-exec-code-" <> suffix)
    rpc_dir = Path.join(base, "rpc")

    File.mkdir!(base)
    :ok = File.chmod(base, 0o700)
    File.mkdir!(rpc_dir)
    :ok = File.chmod(rpc_dir, 0o700)

    File.write!(
      Path.join(base, "lemon_tools.py"),
      PythonShim.render_prelude(rpc_dir, token, config.tools)
    )

    File.write!(Path.join(base, "script.py"), PythonShim.render_script(script, config.tools))

    {base, rpc_dir, token}
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

  defp format(:exit, reason, _stats, _signal, _timeout_ms),
    do: {:error, "execute_code runner crashed: #{inspect(reason)}"}

  defp format(:ok, {:error, reason}, _stats, _signal, _timeout_ms),
    do: {:error, "Error executing script: #{inspect(reason)}"}

  defp format(:ok, {:ok, %BashExecutor.Result{} = result}, stats, signal, timeout_ms) do
    text = result_text(result, signal, timeout_ms)
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

  defp format(:ok, other, _stats, _signal, _timeout_ms),
    do: {:error, "Error executing script: #{inspect(other)}"}

  defp result_text(%BashExecutor.Result{cancelled: true} = result, signal, timeout_ms) do
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

  defp result_text(%BashExecutor.Result{exit_code: 0} = result, _signal, _timeout_ms) do
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

  defp result_text(%BashExecutor.Result{} = result, _signal, _timeout_ms) do
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
