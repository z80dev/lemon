defmodule LemonSim.LLM.Deciders.ExternalDecider do
  @moduledoc """
  Stdio JSONL decider for bring-your-own-agent VendingBench runs.
  """

  use GenServer

  @behaviour LemonSim.Kernel.Decider

  require Logger

  alias AgentCore.Types.{AgentTool, AgentToolResult}
  alias Ai.Types.{Context, ToolCall, UserMessage}
  alias LemonSim.LLM.Deciders.ToolPolicies.SingleTerminal
  alias LemonSim.LLM.Usage

  @protocol "lemon_sim.external.v0"
  @default_decision_timeout_ms 60_000
  @default_max_turns 8

  @impl true
  def decide(%Context{} = context, tools, opts \\ []) when is_list(tools) and is_list(opts) do
    with {:ok, pid} <- fetch_session(opts),
         {:ok, normalized_tools} <- normalize_tools(tools),
         {:ok, policy} <- fetch_policy(opts) do
      timeout_ms = decision_timeout_ms(opts)
      call_timeout = timeout_ms + 5_000

      GenServer.call(
        pid,
        {:decide, context, normalized_tools, policy, opts, timeout_ms},
        call_timeout
      )
    end
  catch
    :exit, {:timeout, _} ->
      {:error, {:live_step_timeout, decision_timeout_ms(opts)}}

    :exit, reason ->
      Logger.warning("External decider exited during decide: #{inspect(reason)}")
      empty_response_error([])
  end

  def start_link(opts) when is_list(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  def stop(pid, reason \\ "complete") when is_pid(pid) do
    GenServer.call(pid, {:stop, reason}, 5_000)
  catch
    :exit, _ -> :ok
  end

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    cmd = Keyword.fetch!(opts, :cmd)
    port = open_port(cmd)

    state = %{
      cmd: cmd,
      port: port,
      os_pid: port_os_pid(port),
      dead?: false,
      exit_status: nil,
      decision_turn: 0,
      line_buffer: ""
    }

    state = mark_dead_on_send_error(state, send_json(port, hello_message(opts)))
    {:ok, state}
  end

  @impl true
  def handle_call({:stop, reason}, _from, state) do
    state = send_game_over(state, reason)
    close_port(state)
    {:stop, :normal, :ok, %{state | dead?: true}}
  end

  def handle_call(
        {:decide, _context, _tools, _policy, _opts, _timeout_ms},
        _from,
        %{dead?: true} = state
      ) do
    {:reply, empty_response_error([]), state}
  end

  def handle_call({:decide, context, tools, policy, opts, timeout_ms}, _from, state) do
    turn = state.decision_turn + 1

    request_result =
      send_json(state.port, %{
        "type" => "decision_request",
        "turn" => turn,
        "observation" => observation(context),
        "tools" => external_tools(tools)
      })

    case request_result do
      :ok ->
        {result, state} = run_loop(state, tools, policy, opts, timeout_ms, turn, 0, [])
        {:reply, result, %{state | decision_turn: turn}}

      {:error, :closed} ->
        {:reply, empty_response_error([]), %{state | dead?: true, decision_turn: turn}}
    end
  end

  @impl true
  def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
    {:noreply, %{state | dead?: true, exit_status: status}}
  end

  def handle_info({:EXIT, port, reason}, %{port: port} = state) do
    {:noreply, %{state | dead?: true, exit_status: reason}}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    close_port(state)
    :ok
  end

  defp run_loop(state, tools, policy, opts, timeout_ms, turn, loop_turn, executed_calls) do
    max_turns =
      Keyword.get(opts, :decision_max_turns, Keyword.get(opts, :max_turns, @default_max_turns))

    if loop_turn >= max_turns do
      {{:error, {:max_turns_exceeded, %{max_turns: max_turns, executed_calls: executed_calls}}},
       state}
    else
      case read_agent_message(state, timeout_ms, turn) do
        {:ok, message, state} ->
          with {:ok, resolved} <- resolve_tool_call(message, tools, turn, loop_turn),
               :ok <- policy.validate_tool_calls([resolved], opts),
               {:ok, step} <- execute_resolved_call(resolved, policy, opts) do
            all_executed_calls = executed_calls ++ [step.executed_call]

            if is_nil(step.decision) do
              send_result =
                send_json(state.port, %{
                  "type" => "tool_result",
                  "turn" => turn,
                  "name" => resolved.tool.name,
                  "result" => tool_result_payload(step.result, step.is_error)
                })

              case send_result do
                :ok ->
                  run_loop(
                    state,
                    tools,
                    policy,
                    opts,
                    timeout_ms,
                    turn,
                    loop_turn + 1,
                    all_executed_calls
                  )

                {:error, :closed} ->
                  {empty_response_error(all_executed_calls), %{state | dead?: true}}
              end
            else
              record_usage_decision(opts)
              {{:ok, Map.put(step.decision, "executed_calls", all_executed_calls)}, state}
            end
          else
            {:error, {:malformed_turn, _details} = reason} ->
              {{:error, reason}, state}

            {:error, reason} ->
              {{:error, reason}, state}
          end

        {:error, {:malformed_turn, _details} = reason, state} ->
          {{:error, reason}, state}

        {:error, :timeout, state} ->
          {{:error, {:live_step_timeout, timeout_ms}}, state}

        {:error, :closed, state} ->
          {empty_response_error(executed_calls), %{state | dead?: true}}

        {:error, reason, state} ->
          {{:error, reason}, state}
      end
    end
  end

  defp fetch_session(opts) do
    case Keyword.get(opts, :external_decider) do
      pid when is_pid(pid) -> {:ok, pid}
      nil -> {:error, :missing_external_decider}
      other -> {:error, {:invalid_external_decider, other}}
    end
  end

  defp open_port(cmd) do
    shell = System.get_env("SHELL") || "/bin/sh"

    Port.open(
      {:spawn_executable, shell},
      [
        :binary,
        :exit_status,
        {:line, 65_536},
        args: ["-lc", cmd]
      ]
    )
  end

  defp hello_message(opts) do
    %{
      "type" => "hello",
      "protocol" => @protocol,
      "sim_id" => Keyword.get(opts, :sim_id),
      "scenario" => "vending_bench",
      "preset" => Keyword.get(opts, :preset),
      "seed" => Keyword.get(opts, :seed),
      "max_days" => Keyword.get(opts, :max_days),
      "max_turns" => Keyword.get(opts, :driver_max_turns, Keyword.get(opts, :max_turns))
    }
  end

  defp read_agent_message(state, timeout_ms, expected_turn) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    read_agent_message_until(state, deadline, expected_turn)
  end

  defp read_agent_message_until(state, deadline, expected_turn) do
    case read_agent_line_until(state, deadline) do
      {:ok, line, state} ->
        case decode_tool_call(line) do
          {:ok, %{turn: turn}} when is_integer(turn) and turn != expected_turn ->
            Logger.debug(
              "Discarding stale external decider response for turn #{inspect(turn)} while waiting for turn #{expected_turn}"
            )

            read_agent_message_until(state, deadline, expected_turn)

          {:ok, message} ->
            {:ok, message, state}

          {:error, reason} ->
            {:error, reason, state}
        end

      other ->
        other
    end
  end

  defp read_agent_line_until(%{port: port} = state, deadline) do
    timeout_ms = max(deadline - System.monotonic_time(:millisecond), 0)

    if timeout_ms == 0 do
      {:error, :timeout, state}
    else
      line_buffer = Map.get(state, :line_buffer, "")

      receive do
        {^port, {:data, {:eol, line}}} ->
          {:ok, line_buffer <> line, %{state | line_buffer: ""}}

        {^port, {:data, {:noeol, line}}} ->
          read_agent_line_until(%{state | line_buffer: line_buffer <> line}, deadline)

        {^port, {:exit_status, status}} ->
          {:error, :closed, %{state | dead?: true, exit_status: status}}

        {:EXIT, ^port, reason} ->
          {:error, :closed, %{state | dead?: true, exit_status: reason}}
      after
        timeout_ms ->
          {:error, :timeout, state}
      end
    end
  end

  defp decode_tool_call(line) when is_binary(line) do
    with {:ok, %{} = decoded} <- Jason.decode(line),
         %{"type" => "tool_call", "name" => name, "arguments" => arguments}
         when is_binary(name) and is_map(arguments) <- decoded,
         :ok <- validate_turn(Map.get(decoded, "turn")) do
      {:ok, %{name: name, arguments: arguments, turn: Map.get(decoded, "turn")}}
    else
      {:ok, other} ->
        {:error, malformed_turn("Expected tool_call object", other)}

      {:error, reason} ->
        {:error, malformed_turn("Invalid JSON: #{Exception.message(reason)}", line)}

      {:invalid_turn, turn} ->
        {:error, malformed_turn("Expected integer turn", %{"turn" => turn})}

      other ->
        {:error, malformed_turn("Expected tool_call object", other)}
    end
  end

  defp validate_turn(nil), do: :ok
  defp validate_turn(turn) when is_integer(turn), do: :ok
  defp validate_turn(turn), do: {:invalid_turn, turn}

  defp malformed_turn(reason, raw) do
    {:malformed_turn, %{reason: reason, raw: raw}}
  end

  defp resolve_tool_call(%{name: name, arguments: arguments}, tools, turn, loop_turn) do
    case find_tool(tools, name) do
      %AgentTool{} = tool ->
        call = %ToolCall{
          id: "external-#{turn}-#{loop_turn + 1}",
          name: tool.name,
          arguments: arguments
        }

        {:ok, %{tool_call: call, tool: tool}}

      nil ->
        {:error, malformed_turn("Unknown tool: #{name}", %{name: name, arguments: arguments})}
    end
  end

  defp execute_resolved_call(%{tool_call: tool_call, tool: tool}, policy, opts) do
    {result, is_error} = execute_tool(tool, tool_call)
    decision = decision_from_tool_call(policy, tool_call, tool, result, is_error, opts)

    executed_call = %{
      tool_name: tool_call.name,
      tool_call_id: tool_call.id,
      arguments: tool_call.arguments,
      is_error: is_error,
      result_text: AgentCore.get_text(result),
      result_details: result.details
    }

    {:ok,
     %{
       result: result,
       is_error: is_error,
       decision: decision,
       executed_call: executed_call
     }}
  end

  defp execute_tool(%AgentTool{} = tool, %ToolCall{} = tool_call) do
    on_update = fn _partial -> :ok end

    try do
      case tool.execute.(tool_call.id, tool_call.arguments || %{}, nil, on_update) do
        {:ok, %AgentToolResult{} = result} -> {result, false}
        {:ok, other} -> {normalize_tool_result(other), false}
        {:error, reason} -> {error_result(reason), true}
        %AgentToolResult{} = result -> {result, false}
        other -> {normalize_tool_result(other), false}
      end
    rescue
      e ->
        {error_result(Exception.message(e)), true}
    catch
      kind, value ->
        {error_result("#{kind}: #{inspect(value)}"), true}
    end
  end

  defp decision_from_tool_call(policy, call, tool, result, false, opts) do
    policy.decision_from_call(call, tool, result, opts)
  end

  defp decision_from_tool_call(_policy, _call, _tool, _result, _is_error, _opts), do: nil

  defp send_game_over(%{dead?: true} = state, _reason), do: state

  defp send_game_over(%{port: port} = state, reason) do
    mark_dead_on_send_error(state, send_json(port, %{"type" => "game_over", "reason" => reason}))
  end

  defp mark_dead_on_send_error(state, :ok), do: state
  defp mark_dead_on_send_error(state, {:error, :closed}), do: %{state | dead?: true}

  defp send_json(nil, _message), do: {:error, :closed}

  defp send_json(port, message) do
    if port_alive?(port) do
      case Port.command(port, Jason.encode!(jsonable(message)) <> "\n") do
        true -> :ok
        false -> {:error, :closed}
      end
    else
      {:error, :closed}
    end
  rescue
    ArgumentError -> {:error, :closed}
  catch
    :exit, _ -> {:error, :closed}
  end

  defp close_port(%{port: port, os_pid: os_pid}) do
    if port_alive?(port) do
      Port.close(port)
    end

    if os_pid_alive?(os_pid) do
      wait_for_os_pid_exit(os_pid, 500)
      terminate_os_pid(os_pid, "TERM")
      wait_for_os_pid_exit(os_pid, 500)
      terminate_os_pid(os_pid, "KILL")
      wait_for_os_pid_exit(os_pid, 500)
    end

    :ok
  rescue
    _ -> :ok
  end

  defp close_port(nil), do: :ok

  defp close_port(port) when is_port(port) do
    close_port(%{port: port, os_pid: port_os_pid(port)})
  end

  defp port_alive?(port) when is_port(port), do: not is_nil(Port.info(port))
  defp port_alive?(_port), do: false

  defp port_os_pid(port) do
    case Port.info(port, :os_pid) do
      {:os_pid, pid} when is_integer(pid) -> pid
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp wait_for_os_pid_exit(nil, _timeout_ms), do: :ok

  defp wait_for_os_pid_exit(os_pid, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    wait_for_os_pid_exit_until(os_pid, deadline)
  end

  defp wait_for_os_pid_exit_until(os_pid, deadline) do
    cond do
      not os_pid_alive?(os_pid) ->
        :ok

      System.monotonic_time(:millisecond) >= deadline ->
        :timeout

      true ->
        Process.sleep(50)
        wait_for_os_pid_exit_until(os_pid, deadline)
    end
  end

  defp os_pid_alive?(nil), do: false

  defp os_pid_alive?(os_pid) when is_integer(os_pid) do
    case System.cmd("kill", ["-0", Integer.to_string(os_pid)], stderr_to_stdout: true) do
      {_, 0} -> true
      _ -> false
    end
  rescue
    _ -> false
  end

  defp terminate_os_pid(nil, _signal), do: :ok

  defp terminate_os_pid(os_pid, signal) when is_integer(os_pid) do
    if os_pid_alive?(os_pid) do
      _ = System.cmd("kill", ["-#{signal}", Integer.to_string(os_pid)], stderr_to_stdout: true)
    end

    :ok
  rescue
    _ -> :ok
  end

  defp observation(%Context{} = context) do
    %{
      "system_prompt" => context.system_prompt,
      "sections" => context.messages |> Enum.flat_map(&message_sections/1)
    }
  end

  defp message_sections(%UserMessage{content: content}) when is_binary(content) do
    parse_sections(content)
  end

  defp message_sections(_message), do: []

  defp parse_sections(prompt) do
    sections =
      prompt
      |> String.split("\n")
      |> Enum.reduce({[], nil, []}, fn line, {sections, current, lines} ->
        case Regex.run(~r/^##\s+(.+)\s*$/, line) do
          [_, title] ->
            sections = flush_section(sections, current, lines)
            {sections, title, []}

          nil ->
            {sections, current, lines ++ [line]}
        end
      end)
      |> then(fn {sections, current, lines} -> flush_section(sections, current, lines) end)

    case sections do
      [] -> [%{"name" => "prompt", "text" => prompt}]
      _ -> sections
    end
  end

  defp flush_section(sections, nil, _lines), do: sections

  defp flush_section(sections, title, lines) do
    text = lines |> Enum.join("\n") |> String.trim()
    sections ++ [%{"name" => section_name(title), "text" => text}]
  end

  defp section_name(title) do
    title
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "_")
    |> String.trim("_")
  end

  defp external_tools(tools) do
    Enum.map(tools, fn %AgentTool{} = tool ->
      %{
        "name" => tool.name,
        "description" => tool.description,
        "parameters" => tool.parameters
      }
    end)
  end

  defp tool_result_payload(%AgentToolResult{} = result, is_error) do
    %{
      "is_error" => is_error,
      "text" => AgentCore.get_text(result),
      "details" => result.details
    }
  end

  defp normalize_tools(tools) do
    with :ok <- ensure_all_tools(tools),
         :ok <- ensure_unique_tool_names(tools) do
      {:ok, tools}
    end
  end

  defp ensure_all_tools(tools) do
    if Enum.all?(tools, &match?(%AgentTool{}, &1)) do
      :ok
    else
      {:error, :invalid_tools}
    end
  end

  defp ensure_unique_tool_names(tools) do
    names = Enum.map(tools, &normalize_name(&1.name))

    dupes =
      names
      |> Enum.frequencies()
      |> Enum.filter(fn {_name, count} -> count > 1 end)
      |> Enum.map(fn {name, _count} -> name end)

    case dupes do
      [] -> :ok
      _ -> {:error, {:duplicate_tool_names, dupes}}
    end
  end

  defp fetch_policy(opts) do
    policy = Keyword.get(opts, :tool_policy, SingleTerminal)

    if is_atom(policy) and Code.ensure_loaded?(policy) and
         function_exported?(policy, :validate_tool_calls, 2) and
         function_exported?(policy, :decision_from_call, 4) do
      {:ok, policy}
    else
      {:error, {:invalid_tool_policy, policy}}
    end
  end

  defp find_tool(tools, name) do
    normalized = normalize_name(name)
    Enum.find(tools, fn %AgentTool{} = tool -> normalize_name(tool.name) == normalized end)
  end

  defp record_usage_decision(opts) do
    Usage.record_external_decision(
      Keyword.get(opts, :usage_collector),
      usage_actor_id(opts),
      external_model_id(opts)
    )
  end

  defp usage_actor_id(opts) do
    case Keyword.get(opts, :usage_actor_id) do
      fun when is_function(fun, 0) -> fun.()
      nil -> "operator"
      actor_id -> actor_id
    end
  end

  defp external_model_id(opts) do
    Keyword.get(opts, :external_model_id) ||
      case Keyword.get(opts, :external_cmd) do
        nil -> "external"
        cmd -> "external:#{cmd}"
      end
  end

  defp decision_timeout_ms(opts) do
    Keyword.get(opts, :external_decision_timeout_ms) ||
      Keyword.get(opts, :live_step_timeout_ms, @default_decision_timeout_ms)
  end

  defp empty_response_error(executed_calls) do
    {:error, {:tool_call_required, %{assistant_text: "", executed_calls: executed_calls}}}
  end

  defp normalize_name(name) when is_binary(name), do: name |> String.trim() |> String.downcase()
  defp normalize_name(name), do: name |> to_string() |> normalize_name()

  defp normalize_tool_result(%AgentToolResult{} = result), do: result

  defp normalize_tool_result(%Ai.Types.TextContent{} = content) do
    %AgentToolResult{content: [content], details: nil, trust: :trusted}
  end

  defp normalize_tool_result(content) when is_binary(content) do
    %AgentToolResult{content: [AgentCore.text_content(content)], details: nil, trust: :trusted}
  end

  defp normalize_tool_result(content) when is_list(content) do
    content
    |> Enum.map(&to_string/1)
    |> Enum.join("\n")
    |> normalize_tool_result()
  end

  defp normalize_tool_result(content), do: normalize_tool_result(inspect(content))

  defp error_result(reason) when is_binary(reason) do
    %AgentToolResult{content: [AgentCore.text_content(reason)], details: nil, trust: :trusted}
  end

  defp error_result(reason), do: error_result(inspect(reason))

  defp jsonable(%_{} = struct) do
    struct
    |> Map.from_struct()
    |> Map.delete(:__struct__)
    |> jsonable()
  end

  defp jsonable(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {json_key(key), jsonable(value)} end)
  end

  defp jsonable(list) when is_list(list), do: Enum.map(list, &jsonable/1)
  defp jsonable(value) when is_atom(value), do: Atom.to_string(value)
  defp jsonable(value), do: value

  defp json_key(key) when is_binary(key), do: key
  defp json_key(key) when is_atom(key), do: Atom.to_string(key)
  defp json_key(key), do: to_string(key)
end
