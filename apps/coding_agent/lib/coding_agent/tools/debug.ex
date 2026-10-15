defmodule CodingAgent.Tools.Debug do
  @moduledoc """
  `debug` tool: drive a Debug Adapter Protocol debugger (lldb-dap, gdb,
  debugpy, dlv) for the current coding session.

  Each coding session has at most one active debug session, owned by a
  `CodingAgent.Debug.SessionServer` that is killed with the coding session.
  Breakpoints may be set before `launch` and persist across relaunches.
  Execution actions (`launch`, `continue`, `step_*`, `pause`) wait for the
  next stop or termination (bounded by `timeout` seconds) and report the stop
  location with a source excerpt.
  """

  alias CodingAgent.Artifacts
  alias CodingAgent.Debug.{Adapters, SessionServer}
  alias CodingAgent.Tools.PathHelpers
  alias LemonAgent.AbortSignal
  alias LemonAgent.Security.ToolResultTrust
  alias LemonAgent.Types.{AgentTool, AgentToolResult}
  alias LemonAi.Types.TextContent

  @actions ~w(launch attach set_breakpoint remove_breakpoint set_function_breakpoint continue
              step_over step_in step_out pause stack_trace threads scopes variables evaluate
              output status sessions terminate custom_request)

  @evaluate_contexts ~w(repl watch hover variables clipboard)

  @default_timeout_s 30
  @max_timeout_s 600
  @default_stack_levels 20
  @max_list_items 200
  @max_value_chars 500
  @max_inline_output_bytes 16_384
  @max_text_bytes 32_768
  @excerpt_radius 3
  @max_excerpt_file_bytes 2_000_000

  @spec tool(String.t(), keyword()) :: AgentTool.t()
  def tool(cwd, opts \\ []) do
    %AgentTool{
      name: "debug",
      description: description(),
      label: "Debug",
      parameters: parameters(),
      execute: &execute(&1, &2, &3, &4, cwd, opts)
    }
  end

  defp description do
    """
    Debugger access through the Debug Adapter Protocol (lldb-dap, gdb, debugpy, dlv). \
    Prefer this over bash for program state, breakpoints, stepping or thread inspection.
    Only one active debug session at a time; terminate it before launching another. \
    `program` is a target path (compiled binary, .py script, Go package dir), not a shell command.
    Typical flow: set_breakpoint (file+line, allowed before launch) → launch → stack_trace → \
    scopes → variables / evaluate → step_over / continue → terminate. Execution actions wait \
    for the next stop up to `timeout` seconds (default #{@default_timeout_s}); if the program is \
    still running, use pause. Without breakpoints, launch stops at program entry.
    """
  end

  defp parameters do
    %{
      "type" => "object",
      "properties" => %{
        "action" => %{"type" => "string", "enum" => @actions, "description" => "Debug action"},
        "program" => %{
          "type" => "string",
          "description" => "launch: debug target path (Delve also accepts Go package directories)"
        },
        "args" => %{
          "type" => "array",
          "items" => %{"type" => "string"},
          "description" => "launch: program arguments"
        },
        "adapter" => %{
          "type" => "string",
          "description" =>
            "Adapter id (lldb-dap, gdb, debugpy, dlv); default chosen from the program"
        },
        "cwd" => %{"type" => "string", "description" => "launch/attach: working directory"},
        "file" => %{"type" => "string", "description" => "Breakpoint source file"},
        "line" => %{"type" => "integer", "minimum" => 1, "description" => "Breakpoint line"},
        "function" => %{"type" => "string", "description" => "Function breakpoint name"},
        "condition" => %{"type" => "string", "description" => "Breakpoint condition"},
        "hit_condition" => %{"type" => "string", "description" => "Breakpoint hit condition"},
        "expression" => %{"type" => "string", "description" => "evaluate: expression"},
        "context" => %{
          "type" => "string",
          "enum" => @evaluate_contexts,
          "description" => "evaluate context (default repl; repl also runs debugger commands)"
        },
        "frame_id" => %{
          "type" => "integer",
          "description" => "Stack frame id (default: top frame of the last stop)"
        },
        "scope_id" => %{"type" => "integer", "description" => "Scope variables reference"},
        "variable_ref" => %{"type" => "integer", "description" => "Variables reference"},
        "thread_id" => %{
          "type" => "integer",
          "description" => "Thread id (default: the stopped thread)"
        },
        "pid" => %{"type" => "integer", "description" => "attach: process id"},
        "host" => %{"type" => "string", "description" => "attach: remote host"},
        "port" => %{"type" => "integer", "description" => "attach: remote port"},
        "levels" => %{
          "type" => "integer",
          "minimum" => 1,
          "description" => "stack_trace: max frames (default #{@default_stack_levels})"
        },
        "command" => %{"type" => "string", "description" => "custom_request: DAP command"},
        "arguments" => %{
          "type" => "object",
          "description" => "custom_request: DAP request arguments"
        },
        "timeout" => %{
          "type" => "number",
          "description" =>
            "Seconds to wait for the adapter / next stop (default #{@default_timeout_s}, max #{@max_timeout_s})"
        }
      },
      "required" => ["action"]
    }
  end

  @spec execute(String.t(), map(), reference() | nil, function() | nil, String.t(), keyword()) ::
          AgentToolResult.t() | {:error, String.t()}
  def execute(_tool_call_id, params, signal, _on_update, cwd, opts) do
    if AbortSignal.aborted?(signal) do
      %AgentToolResult{
        content: [%TextContent{text: "Debug operation cancelled."}],
        is_error: true
      }
    else
      params
      |> do_execute(signal, cwd, opts)
      |> Artifacts.attach(cwd, opts)
      |> ToolResultTrust.untrusted(:shell)
    end
  end

  defp do_execute(params, signal, cwd, opts) do
    with {:ok, action} <- fetch_action(params),
         {:ok, timeout_ms} <- timeout_ms(params),
         {:ok, request} <- build_request(action, params, cwd, opts) do
      key = Keyword.get(opts, :session_id) || {:cwd, Path.expand(cwd)}

      call_opts =
        [owner: Keyword.get(opts, :session_pid), timeout_ms: timeout_ms, signal: signal]
        |> put_opt(:session_key, Keyword.get(opts, :session_key))
        |> put_opt(:idle_timeout_ms, Keyword.get(opts, :debug_idle_timeout_ms))

      key
      |> SessionServer.call(request, call_opts)
      |> to_result(action, request, timeout_ms, cwd, opts)
    end
  end

  # ── Parameter validation ─────────────────────────────────────────────────

  defp fetch_action(%{"action" => action}) when action in @actions, do: {:ok, action}

  defp fetch_action(%{"action" => action}) when is_binary(action),
    do:
      {:error, "Unsupported debug action: #{action}. Valid actions: #{Enum.join(@actions, ", ")}"}

  defp fetch_action(_params), do: {:error, "action is required"}

  defp timeout_ms(params) do
    case Map.get(params, "timeout") do
      nil -> {:ok, @default_timeout_s * 1000}
      s when is_number(s) and s > 0 -> {:ok, round(min(s, @max_timeout_s) * 1000)}
      _ -> {:error, "timeout must be a positive number of seconds (max #{@max_timeout_s})"}
    end
  end

  defp build_request("launch", params, cwd, opts) do
    with {:ok, program} <- required_string(params, "program", "launch"),
         {:ok, command_cwd} <- command_cwd(params, cwd),
         {:ok, args} <- string_list(params, "args"),
         {:ok, adapter_name} <- optional_string(params, "adapter") do
      program = PathHelpers.resolve_path(program, command_cwd)

      kind =
        case File.stat(program) do
          {:ok, %File.Stat{type: :directory}} -> :directory
          {:ok, _} -> :file
          {:error, _} -> :missing
        end

      with :ok <- program_exists(kind, program, cwd),
           {:ok, breakpoint} <- launch_breakpoint(params, cwd),
           {:ok, adapter} <-
             Adapters.select_launch(program, command_cwd, adapter_name, kind, adapter_opts(opts)) do
        {:ok,
         Map.merge(breakpoint, %{
           action: "launch",
           adapter: adapter,
           program: program,
           cwd: command_cwd,
           args: args,
           launch_overrides: Adapters.launch_overrides(adapter, program, kind)
         })}
      end
    end
  end

  defp build_request("attach", params, cwd, opts) do
    with {:ok, command_cwd} <- command_cwd(params, cwd),
         {:ok, adapter_name} <- optional_string(params, "adapter"),
         {:ok, pid} <- optional_integer(params, "pid"),
         {:ok, port} <- optional_integer(params, "port"),
         {:ok, host} <- optional_string(params, "host"),
         :ok <- require_attach_target(pid, port, adapter_name),
         {:ok, adapter} <- Adapters.select_attach(adapter_name, port, adapter_opts(opts)) do
      adapter =
        if adapter.connect_mode == :remote,
          do: Map.merge(adapter, %{host: host || "127.0.0.1", port: port}),
          else: adapter

      {:ok,
       %{action: "attach", adapter: adapter, cwd: command_cwd, pid: pid, port: port, host: host}}
    end
  end

  defp build_request(action, params, cwd, _opts)
       when action in ["set_breakpoint", "remove_breakpoint"] do
    case optional_string(params, "function") do
      {:ok, name} when is_binary(name) ->
        server_action =
          if action == "set_breakpoint",
            do: "set_function_breakpoint",
            else: "remove_function_breakpoint"

        function_request(server_action, name, params)

      {:ok, nil} ->
        with {:ok, file} <- required_string(params, "file", action),
             {:ok, line} <- required_line(params, action),
             {:ok, condition} <- optional_string(params, "condition"),
             {:ok, hit_condition} <- optional_string(params, "hit_condition") do
          {:ok,
           %{
             action: action,
             file: PathHelpers.resolve_path(file, cwd),
             line: line,
             condition: condition,
             hit_condition: hit_condition
           }}
        end

      error ->
        error
    end
  end

  defp build_request("set_function_breakpoint", params, _cwd, _opts) do
    with {:ok, name} <- required_string(params, "function", "set_function_breakpoint") do
      function_request("set_function_breakpoint", name, params)
    end
  end

  defp build_request(action, params, _cwd, _opts)
       when action in ["continue", "step_over", "step_in", "step_out", "pause", "threads"] do
    with {:ok, thread_id} <- optional_integer(params, "thread_id") do
      {:ok, %{action: action, thread_id: thread_id}}
    end
  end

  defp build_request("stack_trace", params, _cwd, _opts) do
    with {:ok, thread_id} <- optional_integer(params, "thread_id"),
         {:ok, levels} <- optional_integer(params, "levels") do
      {:ok, %{action: "stack_trace", thread_id: thread_id, levels: levels && max(levels, 1)}}
    end
  end

  defp build_request("scopes", params, _cwd, _opts) do
    with {:ok, frame_id} <- optional_integer(params, "frame_id") do
      {:ok, %{action: "scopes", frame_id: frame_id}}
    end
  end

  defp build_request("variables", params, _cwd, _opts) do
    with {:ok, variable_ref} <- optional_integer(params, "variable_ref"),
         {:ok, scope_id} <- optional_integer(params, "scope_id") do
      case variable_ref || scope_id do
        nil -> {:error, "variables requires variable_ref or scope_id"}
        ref -> {:ok, %{action: "variables", variable_ref: ref}}
      end
    end
  end

  defp build_request("evaluate", params, _cwd, _opts) do
    with {:ok, expression} <- required_string(params, "expression", "evaluate"),
         {:ok, frame_id} <- optional_integer(params, "frame_id"),
         {:ok, context} <- optional_string(params, "context") do
      if is_nil(context) or context in @evaluate_contexts do
        {:ok, %{action: "evaluate", expression: expression, frame_id: frame_id, context: context}}
      else
        {:error, "context must be one of: #{Enum.join(@evaluate_contexts, ", ")}"}
      end
    end
  end

  defp build_request("custom_request", params, _cwd, _opts) do
    with {:ok, command} <- required_string(params, "command", "custom_request") do
      case Map.get(params, "arguments") do
        nil ->
          {:ok, %{action: "custom_request", command: command, arguments: nil}}

        args when is_map(args) ->
          {:ok, %{action: "custom_request", command: command, arguments: args}}

        _ ->
          {:error, "arguments must be an object"}
      end
    end
  end

  defp build_request(action, _params, _cwd, _opts)
       when action in ["output", "status", "sessions", "terminate"] do
    {:ok, %{action: action}}
  end

  # `launch` may carry one initial breakpoint (file+line or function), added to
  # the pending list before the configuration handshake.
  defp launch_breakpoint(params, cwd) do
    with {:ok, file} <- optional_string(params, "file"),
         {:ok, line} <- optional_integer(params, "line"),
         {:ok, function} <- optional_string(params, "function"),
         {:ok, condition} <- optional_string(params, "condition"),
         {:ok, hit_condition} <- optional_string(params, "hit_condition") do
      cond do
        is_binary(function) ->
          {:ok,
           %{
             function_breakpoint: %{
               function: function,
               condition: condition,
               hit_condition: hit_condition
             }
           }}

        is_binary(file) and is_integer(line) and line > 0 ->
          {:ok,
           %{
             breakpoint: %{
               file: PathHelpers.resolve_path(file, cwd),
               line: line,
               condition: condition,
               hit_condition: hit_condition
             }
           }}

        is_binary(file) or not is_nil(line) ->
          {:error, "launch breakpoints need file and a positive line"}

        true ->
          {:ok, %{}}
      end
    end
  end

  defp function_request(action, name, params) do
    with {:ok, condition} <- optional_string(params, "condition"),
         {:ok, hit_condition} <- optional_string(params, "hit_condition") do
      {:ok, %{action: action, function: name, condition: condition, hit_condition: hit_condition}}
    end
  end

  defp require_attach_target(nil, nil, _adapter), do: {:error, "attach requires pid or port"}

  defp require_attach_target(pid, port, _adapter) when not is_nil(pid) and not is_nil(port),
    do: {:error, "attach accepts either pid or port, not both"}

  defp require_attach_target(pid, nil, _adapter) when is_integer(pid) and pid > 0, do: :ok

  defp require_attach_target(nil, port, _adapter) when is_integer(port) and port in 1..65_535,
    do: :ok

  defp require_attach_target(_, _, _),
    do: {:error, "attach requires a positive pid or port in 1..65535"}

  defp program_exists(:missing, program, cwd),
    do: {:error, "launch program not found: #{display_path(program, cwd)}"}

  defp program_exists(_kind, _program, _cwd), do: :ok

  defp command_cwd(params, cwd) do
    case optional_string(params, "cwd") do
      {:ok, nil} ->
        {:ok, Path.expand(cwd)}

      {:ok, dir} ->
        dir = PathHelpers.resolve_path(dir, cwd)
        if File.dir?(dir), do: {:ok, dir}, else: {:error, "cwd is not a directory: #{dir}"}

      error ->
        error
    end
  end

  defp adapter_opts(opts), do: Keyword.take(opts, [:debug_adapters])

  defp required_string(params, key, action) do
    case Map.get(params, key) do
      value when is_binary(value) ->
        if String.trim(value) == "",
          do: {:error, "#{key} is required for #{action}"},
          else: {:ok, value}

      nil ->
        {:error, "#{key} is required for #{action}"}

      _ ->
        {:error, "#{key} must be a string"}
    end
  end

  defp optional_string(params, key) do
    case Map.get(params, key) do
      nil ->
        {:ok, nil}

      value when is_binary(value) ->
        if String.trim(value) == "", do: {:ok, nil}, else: {:ok, value}

      _ ->
        {:error, "#{key} must be a string"}
    end
  end

  defp optional_integer(params, key) do
    case Map.get(params, key) do
      nil -> {:ok, nil}
      value when is_integer(value) -> {:ok, value}
      value when is_float(value) and value == trunc(value) -> {:ok, trunc(value)}
      _ -> {:error, "#{key} must be an integer"}
    end
  end

  defp required_line(params, action) do
    case optional_integer(params, "line") do
      {:ok, line} when is_integer(line) and line > 0 -> {:ok, line}
      {:ok, nil} -> {:error, "#{action} requires file+line or function"}
      _ -> {:error, "line must be a positive integer"}
    end
  end

  defp string_list(params, key) do
    case Map.get(params, key) do
      nil ->
        {:ok, nil}

      list when is_list(list) ->
        if Enum.all?(list, &is_binary/1), do: {:ok, list}, else: list_error(key)

      _ ->
        list_error(key)
    end
  end

  defp list_error(key), do: {:error, "#{key} must be an array of strings"}

  # ── Results ──────────────────────────────────────────────────────────────

  defp to_result({:error, message}, _action, _request, _timeout_ms, _cwd, _opts),
    do: {:error, message}

  defp to_result({:aborted, message}, action, _request, _timeout_ms, _cwd, _opts) do
    %AgentToolResult{
      content: [%TextContent{text: message}],
      details: %{action: action, success: false, cancelled: true},
      is_error: true
    }
  end

  defp to_result({:none, message}, action, _request, _timeout_ms, _cwd, _opts) do
    case action do
      a when a in ["status", "sessions"] ->
        text_result("No debug sessions.", %{action: action, sessions: []})

      "terminate" ->
        text_result("No debug session to terminate.", %{action: action})

      _ ->
        {:error, message}
    end
  end

  defp to_result({:ok, data}, action, request, timeout_ms, cwd, opts) do
    format(action, data, request, timeout_ms, cwd, opts)
  end

  defp format("launch", data, request, timeout_ms, cwd, _opts) do
    snapshot = data.snapshot

    header =
      "Launched #{display_path(request.program, cwd)} with #{data.adapter} (session #{snapshot.id})."

    text =
      [header, outcome_text(data, timeout_ms, cwd), breakpoint_summary(snapshot, cwd)]
      |> join_sections()

    text_result(text, outcome_details("launch", data))
  end

  defp format("attach", data, request, timeout_ms, cwd, _opts) do
    target =
      cond do
        request.pid -> "pid #{request.pid}"
        request.port -> "#{request.host || "localhost"}:#{request.port}"
        true -> "adapter target"
      end

    header = "Attached to #{target} with #{data.adapter} (session #{data.snapshot.id})."
    text = join_sections([header, outcome_text(data, timeout_ms, cwd)])
    text_result(text, outcome_details("attach", data))
  end

  defp format(action, data, _request, _timeout_ms, cwd, _opts)
       when action in ["set_breakpoint", "remove_breakpoint", "set_function_breakpoint"] do
    {text, details} =
      case data do
        %{function_breakpoints: breakpoints} ->
          {format_function_breakpoints(breakpoints, data.pending),
           %{function_breakpoints: breakpoints}}

        %{file: file, breakpoints: breakpoints} ->
          {format_source_breakpoints(file, breakpoints, data.pending, cwd),
           %{file: file, breakpoints: breakpoints}}
      end

    text_result(
      text,
      Map.merge(
        %{action: action, success: true, snapshot: data.snapshot, pending: data.pending},
        details
      )
    )
  end

  defp format(action, data, _request, timeout_ms, cwd, _opts)
       when action in ["continue", "step_over", "step_in", "step_out", "pause"] do
    text_result(outcome_text(data, timeout_ms, cwd), outcome_details(action, data))
  end

  defp format("stack_trace", data, _request, _timeout_ms, cwd, _opts) do
    frames = data.stack_frames

    lines =
      frames
      |> Enum.with_index()
      |> Enum.map(fn {frame, index} ->
        "##{index} #{frame["name"]} #{frame_location(frame, cwd)} (frame_id #{frame["id"]})"
      end)

    more =
      case data.total_frames do
        total when is_integer(total) and total > length(frames) ->
          ["… #{total - length(frames)} more frames (raise levels)"]

        _ ->
          []
      end

    text = Enum.join(["Stack trace (thread #{data.snapshot.thread_id}):" | lines ++ more], "\n")
    text = if frames == [], do: "Stack trace: (empty)", else: text

    text_result(text, %{
      action: "stack_trace",
      success: true,
      snapshot: data.snapshot,
      stack_frames: frames
    })
  end

  defp format("threads", data, _request, _timeout_ms, _cwd, _opts) do
    current = data.snapshot[:thread_id]

    lines =
      Enum.map(data.threads, fn thread ->
        marker = if thread["id"] == current, do: "* ", else: "  "
        "#{marker}#{thread["id"]}: #{thread["name"]}"
      end)

    text = if lines == [], do: "Threads: (none)", else: Enum.join(["Threads:" | lines], "\n")

    text_result(text, %{
      action: "threads",
      success: true,
      snapshot: data.snapshot,
      threads: data.threads
    })
  end

  defp format("scopes", data, _request, _timeout_ms, _cwd, _opts) do
    lines =
      Enum.map(data.scopes, fn scope ->
        expensive = if scope["expensive"], do: " (expensive)", else: ""
        "#{scope["name"]} [scope_id #{scope["variablesReference"]}]#{expensive}"
      end)

    text =
      if lines == [],
        do: "Scopes: (none)",
        else: Enum.join(["Scopes (frame #{data.frame_id}):" | lines], "\n")

    text_result(text, %{
      action: "scopes",
      success: true,
      snapshot: data.snapshot,
      scopes: data.scopes
    })
  end

  defp format("variables", data, _request, _timeout_ms, _cwd, _opts) do
    {shown, hidden} = Enum.split(data.variables, @max_list_items)

    lines =
      Enum.map(shown, fn variable ->
        type = if present?(variable["type"]), do: " (#{variable["type"]})", else: ""
        ref = variable["variablesReference"]
        ref_text = if is_integer(ref) and ref > 0, do: " [ref #{ref}]", else: ""
        "#{variable["name"]} = #{clip(variable["value"])}#{type}#{ref_text}"
      end)

    lines = if hidden == [], do: lines, else: lines ++ ["… #{length(hidden)} more variables"]
    text = if lines == [], do: "Variables: (none)", else: Enum.join(lines, "\n")

    text_result(text, %{
      action: "variables",
      success: true,
      snapshot: data.snapshot,
      variables: shown,
      omitted: length(hidden)
    })
  end

  defp format("evaluate", data, _request, _timeout_ms, _cwd, _opts) do
    evaluation = data.evaluation
    lines = ["Result: #{clip(evaluation["result"], 8_000)}"]

    lines =
      if present?(evaluation["type"]), do: lines ++ ["Type: #{evaluation["type"]}"], else: lines

    lines =
      case evaluation["variablesReference"] do
        ref when is_integer(ref) and ref > 0 -> lines ++ ["Variables ref: #{ref}"]
        _ -> lines
      end

    text_result(Enum.join(lines, "\n"), %{
      action: "evaluate",
      success: true,
      snapshot: data.snapshot,
      evaluation: evaluation
    })
  end

  defp format("custom_request", data, request, _timeout_ms, _cwd, _opts) do
    body = Jason.encode!(data.body, pretty: true)

    text_result("#{request.command} response:\n#{body}", %{
      action: "custom_request",
      success: true,
      snapshot: data.snapshot,
      body: data.body
    })
  end

  defp format("output", data, _request, _timeout_ms, cwd, opts) do
    output = data.output
    size = byte_size(output)
    details = %{action: "output", success: true, snapshot: data.snapshot, output_bytes: size}

    cond do
      output == "" ->
        text_result("(no output captured)", details)

      size <= @max_inline_output_bytes ->
        text_result(output, details)

      true ->
        tail = binary_part(output, size - @max_inline_output_bytes, @max_inline_output_bytes)
        tail = drop_partial_utf8(tail)

        {notice, details} =
          case spill_output(output, cwd, opts) do
            {:ok, path} ->
              {"[Showing the last #{byte_size(tail)} of #{size} buffered bytes; full buffer saved to #{path}]",
               Map.merge(details, %{truncated: true, full_output_path: path})}

            :error ->
              {"[Showing the last #{byte_size(tail)} of #{size} buffered bytes]",
               Map.put(details, :truncated, true)}
          end

        text_result("#{notice}\n#{tail}", details)
    end
  end

  defp format(action, data, _request, _timeout_ms, cwd, _opts)
       when action in ["status", "sessions"] do
    snapshot = data.snapshot

    text =
      case snapshot.status do
        :none -> join_sections(["No active debug session.", breakpoint_summary(snapshot, cwd)])
        _ -> join_sections([snapshot_text(snapshot, cwd), breakpoint_summary(snapshot, cwd)])
      end

    sessions = if snapshot.status == :none, do: [], else: [snapshot]
    text_result(text, %{action: action, success: true, snapshot: snapshot, sessions: sessions})
  end

  defp format("terminate", %{snapshot: nil}, _request, _timeout_ms, _cwd, _opts) do
    text_result("No debug session to terminate.", %{action: "terminate", success: true})
  end

  defp format("terminate", data, _request, _timeout_ms, _cwd, _opts) do
    snapshot = data.snapshot

    text =
      join_sections([
        "Debug session #{snapshot.id} terminated.",
        exit_line(snapshot),
        output_hint(snapshot)
      ])

    text_result(text, %{action: "terminate", success: true, snapshot: snapshot})
  end

  # ── Formatting helpers ───────────────────────────────────────────────────

  defp outcome_details(action, data) do
    %{
      action: action,
      success: true,
      snapshot: data.snapshot,
      state: data.state,
      timed_out: data.timed_out
    }
  end

  defp outcome_text(%{state: :stopped, snapshot: snapshot}, _timeout_ms, cwd) do
    join_sections([stop_line(snapshot, cwd), excerpt(snapshot.source_path, snapshot.line, cwd)])
  end

  defp outcome_text(%{state: :terminated, snapshot: snapshot}, _timeout_ms, _cwd) do
    error = if snapshot.error, do: "Adapter: #{snapshot.error}", else: nil
    join_sections(["Program terminated#{exit_suffix(snapshot)}.", error, output_hint(snapshot)])
  end

  defp outcome_text(%{state: :running, timed_out: true}, timeout_ms, _cwd) do
    "Program is still running after #{format_seconds(timeout_ms)}. " <>
      "Use pause to interrupt and inspect state, or continue with a larger timeout."
  end

  defp outcome_text(_data, _timeout_ms, _cwd), do: "Program is running."

  defp stop_line(snapshot, cwd) do
    reason = snapshot.stop_reason || "paused"

    description =
      if present?(snapshot.stop_description) and snapshot.stop_description != reason,
        do: " (#{snapshot.stop_description})",
        else: ""

    location =
      case {snapshot.source_path, snapshot.line} do
        {path, line} when is_binary(path) and is_integer(line) ->
          " at #{display_path(path, cwd)}:#{line}"

        _ ->
          ""
      end

    frame = if present?(snapshot.frame_name), do: " in #{snapshot.frame_name}", else: ""
    thread = if snapshot.thread_id, do: " (thread #{snapshot.thread_id})", else: ""
    "Stopped: #{reason}#{description}#{location}#{frame}#{thread}"
  end

  defp snapshot_text(snapshot, cwd) do
    lines = [
      "Session #{snapshot.id} (#{snapshot.adapter}): #{snapshot.status}",
      snapshot.program && "Program: #{display_path(snapshot.program, cwd)}",
      snapshot.process_id && "Process id: #{snapshot.process_id}",
      snapshot.status == :stopped && stop_line(snapshot, cwd),
      snapshot.status == :terminated && exit_line(snapshot),
      snapshot.error && "Adapter: #{snapshot.error}",
      snapshot.output_bytes > 0 && output_hint(snapshot)
    ]

    lines |> Enum.filter(&is_binary/1) |> Enum.join("\n")
  end

  defp exit_line(snapshot) do
    if is_integer(snapshot.exit_code), do: "Exit code: #{snapshot.exit_code}", else: nil
  end

  defp exit_suffix(snapshot) do
    if is_integer(snapshot.exit_code), do: " with exit code #{snapshot.exit_code}", else: ""
  end

  defp output_hint(%{output_bytes: bytes}) when is_integer(bytes) and bytes > 0,
    do: "Captured #{bytes} bytes of program/adapter output (action: output)."

  defp output_hint(_snapshot), do: nil

  defp breakpoint_summary(snapshot, cwd) do
    source =
      Enum.map(snapshot.breakpoints, fn bp ->
        "- #{display_path(bp.file, cwd)}:#{bp.line} #{breakpoint_state(bp)}"
      end)

    functions = Enum.map(snapshot.function_breakpoints, &"- #{&1.name}() #{breakpoint_state(&1)}")

    case source ++ functions do
      [] -> nil
      lines -> Enum.join(["Breakpoints:" | lines], "\n")
    end
  end

  defp format_source_breakpoints(file, breakpoints, pending, cwd) do
    header = "Breakpoints for #{display_path(file, cwd)}:"

    lines =
      case breakpoints do
        [] -> ["(none)"]
        list -> Enum.map(list, &"- line #{&1.line}: #{breakpoint_state(&1, pending)}")
      end

    Enum.join([header | lines], "\n")
  end

  defp format_function_breakpoints(breakpoints, pending) do
    lines =
      case breakpoints do
        [] -> ["(none)"]
        list -> Enum.map(list, &"- #{&1.name}: #{breakpoint_state(&1, pending)}")
      end

    Enum.join(["Function breakpoints:" | lines], "\n")
  end

  defp breakpoint_state(bp, pending \\ false) do
    state =
      cond do
        pending -> "pending (sent at launch)"
        bp.verified -> "verified"
        true -> "unverified"
      end

    condition = if bp.condition, do: " if #{bp.condition}", else: ""
    hit = if bp.hit_condition, do: " hits #{bp.hit_condition}", else: ""
    message = if present?(bp.message), do: " (#{bp.message})", else: ""
    state <> condition <> hit <> message
  end

  defp frame_location(frame, cwd) do
    path = get_in(frame, ["source", "path"]) || get_in(frame, ["source", "name"])

    case {path, frame["line"]} do
      {path, line} when is_binary(path) and is_integer(line) and line > 0 ->
        "#{display_path(path, cwd)}:#{line}"

      _ ->
        "<no source>"
    end
  end

  defp excerpt(path, line, cwd) when is_binary(path) and is_integer(line) and line > 0 do
    with {:ok, %File.Stat{type: :regular, size: size}} <- File.stat(path),
         true <- size <= @max_excerpt_file_bytes,
         {:ok, content} <- File.read(path) do
      lines = String.split(content, ~r/\r?\n/)
      first = max(line - @excerpt_radius, 1)
      last = min(line + @excerpt_radius, length(lines))
      width = last |> Integer.to_string() |> String.length()

      body =
        for number <- first..last//1 do
          marker = if number == line, do: ">", else: " "
          text = lines |> Enum.at(number - 1, "") |> clip(200)
          "#{marker} #{String.pad_leading(Integer.to_string(number), width)} | #{text}"
        end

      if body == [], do: nil, else: Enum.join(["#{display_path(path, cwd)}:" | body], "\n")
    else
      _ -> nil
    end
  end

  defp excerpt(_path, _line, _cwd), do: nil

  defp spill_output(output, cwd, opts) do
    directory =
      case Artifacts.spill_dir(cwd, opts) do
        {:ok, dir} -> dir
        {:error, _} -> Path.join(System.tmp_dir!(), "lemon-debug")
      end

    name = "debug-output-#{System.unique_integer([:positive])}.log"
    path = Path.join(directory, name)

    with :ok <- File.mkdir_p(directory),
         :ok <- File.write(path, output) do
      {:ok, path}
    else
      _ -> :error
    end
  rescue
    _ -> :error
  end

  defp text_result(text, details) do
    %AgentToolResult{content: [%TextContent{text: cap_text(text)}], details: details}
  end

  defp cap_text(text) when byte_size(text) <= @max_text_bytes, do: text

  defp cap_text(text) do
    head = text |> binary_part(0, @max_text_bytes) |> drop_trailing_partial_utf8()
    head <> "\n… [output truncated]"
  end

  defp join_sections(sections) do
    sections |> Enum.filter(&(is_binary(&1) and &1 != "")) |> Enum.join("\n")
  end

  defp display_path(path, cwd) when is_binary(path) do
    expanded_cwd = Path.expand(cwd)

    case Path.relative_to(path, expanded_cwd) do
      ^path -> path
      relative -> relative
    end
  end

  defp clip(value, max \\ @max_value_chars)
  defp clip(nil, _max), do: ""

  defp clip(value, max) when is_binary(value) do
    if String.length(value) > max, do: String.slice(value, 0, max) <> "…", else: value
  end

  defp clip(value, max), do: value |> inspect() |> clip(max)

  defp present?(value), do: is_binary(value) and String.trim(value) != ""

  defp format_seconds(ms) when rem(ms, 1000) == 0, do: "#{div(ms, 1000)}s"
  defp format_seconds(ms), do: "#{Float.round(ms / 1000, 1)}s"

  defp drop_partial_utf8(<<byte, rest::binary>>) when byte in 0x80..0xBF,
    do: drop_partial_utf8(rest)

  defp drop_partial_utf8(binary), do: binary

  defp drop_trailing_partial_utf8(binary) do
    if String.valid?(binary),
      do: binary,
      else: drop_trailing_partial_utf8(binary_part(binary, 0, byte_size(binary) - 1))
  end

  defp put_opt(opts, _key, nil), do: opts
  defp put_opt(opts, key, value), do: Keyword.put(opts, key, value)
end
