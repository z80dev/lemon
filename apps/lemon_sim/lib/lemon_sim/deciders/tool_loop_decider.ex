defmodule LemonSim.Deciders.ToolLoopDecider do
  @moduledoc """
  Concrete decider that executes a model/tool loop until a decision is produced.

  The decider validates assistant tool-call batches with a pluggable policy and
  stops once that policy selects a terminal decision.
  """

  @behaviour LemonSim.Decider

  alias AgentCore.Types.{AgentTool, AgentToolResult}
  alias Ai.Types.{AssistantMessage, Context, Tool, ToolCall, ToolResultMessage}
  alias LemonSim.Deciders.ToolPolicies.SingleTerminal

  @default_max_turns 8
  @default_max_tool_calls_per_turn 16

  @type decision :: map()
  @type complete_fn ::
          (Ai.Types.Model.t(), Context.t(), map() ->
             {:ok, AssistantMessage.t()} | {:error, term()})

  @impl true
  def decide(%Context{} = context, tools, opts \\ []) when is_list(tools) and is_list(opts) do
    with {:ok, model} <- fetch_model(opts),
         {:ok, normalized_tools} <- normalize_tools(tools),
         {:ok, policy} <- fetch_policy(opts) do
      loop_state = %{
        context: with_llm_tools(context, normalized_tools),
        tools: normalized_tools,
        policy: policy,
        decisions: [],
        executed_calls: []
      }

      run_loop(loop_state, model, opts, 0)
    end
  end

  defp run_loop(state, model, opts, turn) do
    max_turns = Keyword.get(opts, :max_turns, @default_max_turns)

    max_tool_calls_per_turn =
      Keyword.get(opts, :max_tool_calls_per_turn, @default_max_tool_calls_per_turn)

    if turn >= max_turns do
      {:error,
       {:max_turns_exceeded, %{max_turns: max_turns, executed_calls: state.executed_calls}}}
    else
      complete_fn = Keyword.get(opts, :complete_fn, &Ai.complete/3)
      stream_options = Keyword.get(opts, :stream_options, %{})

      with {:ok, %AssistantMessage{} = assistant} <-
             complete_fn.(model, state.context, stream_options),
           context_with_assistant <- append_message(state.context, assistant) do
        with {:ok, tool_calls} <- fetch_tool_calls(assistant, max_tool_calls_per_turn) do
          case tool_calls do
            [] ->
              {:ok, text_decision(assistant, state.executed_calls)}

            calls ->
              with {:ok, resolved_calls} <- resolve_tool_calls(calls, state.tools),
                   :ok <- state.policy.validate_tool_calls(resolved_calls, opts),
                   {:ok, step} <-
                     execute_tool_calls(
                       resolved_calls,
                       context_with_assistant,
                       state.policy,
                       opts
                     ) do
                all_executed_calls = state.executed_calls ++ step.executed_calls

                if Keyword.get(opts, :stop_on_decision_tool, true) and not is_nil(step.decision) do
                  {:ok, put_executed_calls(step.decision, all_executed_calls)}
                else
                  next_state = %{
                    state
                    | context: step.context,
                      executed_calls: all_executed_calls,
                      decisions: state.decisions ++ List.wrap(step.decision)
                  }

                  run_loop(next_state, model, opts, turn + 1)
                end
              end
          end
        end
      end
    end
  end

  defp execute_tool_calls(resolved_tool_calls, context, policy, opts) do
    Enum.reduce_while(
      resolved_tool_calls,
      {:ok, %{context: context, decision: nil, executed_calls: []}},
      fn %{tool_call: tool_call, tool: tool}, {:ok, acc} ->
        case execute_single_tool_call(tool_call, tool, acc.context, policy, opts) do
          {:ok, result} ->
            next = %{
              context: result.context,
              decision: result.decision,
              executed_calls: acc.executed_calls ++ [result.executed_call]
            }

            if is_nil(result.decision) do
              {:cont, {:ok, next}}
            else
              {:halt, {:ok, next}}
            end

          {:error, _reason} = error ->
            {:halt, error}
        end
      end
    )
  end

  defp execute_single_tool_call(
         %ToolCall{} = tool_call,
         %AgentTool{} = tool,
         context,
         policy,
         opts
       ) do
    {result, is_error} = execute_tool(tool, tool_call)

    tool_result_message = to_tool_result_message(tool_call, result, is_error)
    next_context = append_message(context, tool_result_message)

    decision = decision_from_tool_call(policy, tool_call, tool, result, is_error, opts)

    executed_call = %{
      tool_name: tool_call.name,
      tool_call_id: tool_call.id,
      arguments: tool_call.arguments,
      is_error: is_error,
      result_text: AgentCore.get_text(result),
      result_details: result.details
    }

    {:ok, %{context: next_context, decision: decision, executed_call: executed_call}}
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

  defp normalize_tools(tools) do
    if Enum.all?(tools, &match?(%AgentTool{}, &1)) do
      {:ok, dedupe_tools(tools)}
    else
      {:error, :invalid_tools}
    end
  end

  defp dedupe_tools(tools) do
    tools
    |> Enum.reduce(%{}, fn %AgentTool{} = tool, acc ->
      Map.put(acc, normalize_name(tool.name), tool)
    end)
    |> Map.values()
  end

  defp with_llm_tools(%Context{} = context, tools) do
    llm_tools =
      Enum.map(tools, fn %AgentTool{} = tool ->
        %Tool{name: tool.name, description: tool.description, parameters: tool.parameters}
      end)

    %{context | tools: llm_tools}
  end

  defp append_message(%Context{} = context, message) do
    %{context | messages: context.messages ++ [message]}
  end

  defp fetch_policy(opts) do
    policy = Keyword.get(opts, :tool_policy, SingleTerminal)

    if is_atom(policy) and function_exported?(policy, :validate_tool_calls, 2) and
         function_exported?(policy, :decision_from_call, 4) do
      {:ok, policy}
    else
      {:error, {:invalid_tool_policy, policy}}
    end
  end

  defp fetch_model(opts) do
    case Keyword.get(opts, :model) do
      %Ai.Types.Model{} = model -> {:ok, model}
      _ -> {:error, :missing_model}
    end
  end

  defp fetch_tool_calls(%AssistantMessage{} = assistant, max_tool_calls_per_turn) do
    tool_calls = Ai.get_tool_calls(assistant)

    if length(tool_calls) > max_tool_calls_per_turn do
      {:error,
       {:max_tool_calls_per_turn_exceeded,
        %{max_tool_calls_per_turn: max_tool_calls_per_turn, tool_calls: length(tool_calls)}}}
    else
      {:ok, tool_calls}
    end
  end

  defp resolve_tool_calls(tool_calls, tools) do
    Enum.reduce_while(tool_calls, {:ok, []}, fn %ToolCall{} = tool_call, {:ok, acc} ->
      case find_tool(tools, tool_call.name) do
        %AgentTool{} = tool ->
          {:cont, {:ok, acc ++ [%{tool_call: tool_call, tool: tool}]}}

        nil ->
          {:halt, {:error, {:unknown_tool, tool_call.name}}}
      end
    end)
  end

  defp find_tool(tools, name) do
    normalized = normalize_name(name)
    Enum.find(tools, fn %AgentTool{} = tool -> normalize_name(tool.name) == normalized end)
  end

  defp normalize_name(name) when is_binary(name), do: name |> String.trim() |> String.downcase()
  defp normalize_name(name), do: name |> to_string() |> normalize_name()

  defp to_tool_result_message(%ToolCall{} = call, %AgentToolResult{} = result, is_error) do
    %ToolResultMessage{
      role: :tool_result,
      tool_call_id: call.id,
      tool_name: call.name,
      content: result.content || [],
      details: result.details,
      trust: normalize_trust(result.trust),
      is_error: is_error,
      timestamp: System.system_time(:millisecond)
    }
  end

  defp decision_from_tool_call(
         policy,
         %ToolCall{} = call,
         %AgentTool{} = tool,
         result,
         false,
         opts
       ) do
    policy.decision_from_call(call, tool, result, opts)
  end

  defp decision_from_tool_call(_policy, _call, _tool, _result, _is_error, _opts), do: nil

  defp text_decision(%AssistantMessage{} = assistant, executed_calls) do
    %{
      "type" => "assistant_text",
      "text" => Ai.get_text(assistant),
      "executed_calls" => executed_calls
    }
  end

  defp put_executed_calls(%{} = decision, executed_calls) do
    Map.put(decision, "executed_calls", executed_calls)
  end

  defp normalize_trust(:untrusted), do: :untrusted
  defp normalize_trust(_), do: :trusted

  defp normalize_tool_result(%AgentToolResult{} = result), do: result

  defp normalize_tool_result(%Ai.Types.TextContent{} = content) do
    %AgentToolResult{content: [content], details: nil, trust: :trusted}
  end

  defp normalize_tool_result(content) when is_binary(content) do
    %AgentToolResult{content: [AgentCore.text_content(content)], details: nil, trust: :trusted}
  end

  defp normalize_tool_result(content) when is_list(content) do
    text =
      content
      |> Enum.map(&to_string/1)
      |> Enum.join("\n")

    normalize_tool_result(text)
  end

  defp normalize_tool_result(content) do
    normalize_tool_result(inspect(content))
  end

  defp error_result(reason) when is_binary(reason) do
    %AgentToolResult{content: [AgentCore.text_content(reason)], details: nil, trust: :trusted}
  end

  defp error_result(reason), do: error_result(inspect(reason))
end
