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
  locally only. Persistent interpreter state follows the same rule:
  `kernel_mode = "session"`, the kernel bounds, and the optional `reset`
  parameter freeze the public/config contract now, but every run still executes
  per-call until the supervised session path lands.
  """

  import Bitwise

  alias CodingAgent.BashExecutor
  alias CodingAgent.Tools
  alias CodingAgent.Tools.ExecuteCode.{Config, PythonShim, Rpc}
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
      `:approval_context`, plus the `@doc false` test seams `:python_finder`,
      `:script_runner` and `:execute_code_tool_overrides`)
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
        run(script, python, config, params, signal, cwd, opts)
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

  # `reset` asks for a fresh interpreter in session mode. The persistent path
  # is not wired yet, so per-call runs validate it and treat it as redundant.
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
    base = build_workspace(script, config)
    rpc_dir = Path.join(base, "rpc")

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
        poll_interval_ms: @poll_interval_ms
      }

      {outcome, task_result, stats} = Rpc.serve(task, ctx)

      emit_telemetry(started_at, stats, task_result)
      format(outcome, task_result, stats, signal, timeout_ms)
    after
      File.rm_rf(base)
    end
  end

  defp clamp_timeout(value, %Config{timeout_ms: max_ms}) when is_integer(value),
    do: max(@min_timeout_ms, min(value, max_ms))

  defp clamp_timeout(_value, %Config{timeout_ms: max_ms}), do: max_ms

  defp build_workspace(script, %Config{} = config) do
    suffix = :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
    base = Path.join(System.tmp_dir!(), "lemon-exec-code-" <> suffix)
    rpc_dir = Path.join(base, "rpc")

    File.mkdir_p!(rpc_dir)
    File.chmod(base, 0o700)

    File.write!(
      Path.join(base, "lemon_tools.py"),
      PythonShim.render_prelude(rpc_dir, config.tools)
    )

    File.write!(Path.join(base, "script.py"), PythonShim.render_script(script, config.tools))

    base
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
