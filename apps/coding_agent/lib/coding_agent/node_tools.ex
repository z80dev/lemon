defmodule CodingAgent.NodeTools do
  @moduledoc """
  Routes single tool calls to named execution nodes.

  A session whose policy allows the `nodes` tool gets an optional `node`
  argument on the routable built-ins (`routable/0`). A call naming a node runs
  that one call on the node through the `coding_agent.tool` method, with the
  node's files, shell and network; the model loop, journal and provider
  credentials stay here. Calls without `node` (or with `"local"`) run locally.

  The wrapper sits inside the approval, hook and disclosure wrappers, so a
  routed call is reviewed with its `node` argument visible, and outside the
  session mutation lock, so remote calls never serialize local workspace
  mutations.

  Remote calls never fall back to another machine and are never retried. A
  call that was dispatched but did not report back (timeout or dropped
  connection) is returned as an unknown outcome: it may have run.

  Effectful calls pass the controller's durable intent gate before transmission.
  Their JSON request includes a `toolIntent` acknowledgement bound to the exact
  call ID; the destination does not create a second journal.

  The same module owns the JSON result codec shared with the destination
  (`CodingAgent.ExecutionNode.ToolService`). Interrupted outcome and reason
  values are normalized to the shared atom vocabulary when decoded here;
  refusals are `:not_started` / `:skipped`, and lost results are
  `:unknown` / `:interrupted`.
  """

  alias LemonAgent.AbortSignal
  alias LemonAgent.Security.ToolResultTrust
  alias LemonAgent.Types.{AgentTool, AgentToolResult}
  alias LemonAi.Types.{ImageContent, TextContent}
  alias LemonCore.ExecutionContext
  alias LemonAgent.NodeRegistry

  @method "coding_agent.tool"
  @version 1
  @routable ~w(bash bash_output kill_process process_input read write edit ls grep find eval)
  @max_details_bytes 65_536
  @default_timeout_ms 300_000
  @max_timeout_ms 1_800_000
  @margin_ms 60_000
  # Backstop for a lost broker deadline; the broker's own timeout fires first.
  @await_grace_ms 15_000

  @node_parameter %{
    "type" => "string",
    "description" =>
      "Run this call on a connected machine (see nodes), with its files and shell; omit to run here."
  }

  @doc "Wire method for one routed tool call."
  def method, do: @method

  @doc "Protocol version of `coding_agent.tool`."
  def version, do: @version

  @doc "Built-in tools that accept a `node` argument."
  def routable, do: @routable

  @doc "Capability descriptor a destination advertises for `coding_agent.tool`."
  def capability do
    %{"version" => @version, "tools" => @routable, "executionContext" => %{"version" => 1}}
  end

  @doc """
  Adds node routing to routable built-in tuples when the build includes the
  `nodes` tool. Without `nodes`, routable built-ins refuse a call that names a
  remote node instead of silently running it here.
  """
  @spec wrap_tuples([{String.t(), AgentTool.t(), term()}], keyword()) ::
          [{String.t(), AgentTool.t(), term()}]
  def wrap_tuples(tuples, opts) do
    routing? = Enum.any?(tuples, fn {name, _tool, _source} -> name == "nodes" end)

    Enum.map(tuples, fn
      {"eval", tool, :builtin} ->
        # Remote tool sessions may use the ordinary full-authority eval kernel.
        # Never silently switch a code-mode cell to that different runtime.
        tool =
          if CodingAgent.Tools.CodeMode.enabled?(opts),
            do: refuse_remote(tool),
            else: if(routing?, do: wrap(tool, opts), else: refuse_remote(tool))

        {"eval", tool, :builtin}

      {name, tool, :builtin} when name in @routable ->
        {name, if(routing?, do: wrap(tool, opts), else: refuse_remote(tool)), :builtin}

      tuple ->
        tuple
    end)
  end

  @doc "Whether tool arguments name a remote node."
  @spec remote_call?(term()) :: boolean()
  def remote_call?(params), do: match?({:remote, _}, selector(params))

  defp wrap(%AgentTool{} = tool, opts) do
    execute = tool.execute
    name = tool.name

    %{
      tool
      | parameters: put_node_parameter(tool.parameters),
        execute: fn tool_call_id, params, signal, on_update ->
          case selector(params) do
            :local ->
              execute.(tool_call_id, Map.delete(params, "node"), signal, on_update)

            {:remote, node} ->
              run_remote(name, node, Map.delete(params, "node"), tool_call_id, signal, opts)

            {:error, message} ->
              error_result(message, %{outcome: :not_started, reason: :skipped})
          end
        end
    }
  end

  defp refuse_remote(%AgentTool{} = tool) do
    execute = tool.execute

    %{
      tool
      | execute: fn tool_call_id, params, signal, on_update ->
          case selector(params) do
            :local ->
              execute.(tool_call_id, Map.delete(params, "node"), signal, on_update)

            _ ->
              error_result(
                "Not run: this session cannot route calls to other machines (the nodes tool " <>
                  "is not allowed). Omit node to run here.",
                %{outcome: :not_started, reason: :skipped}
              )
          end
        end
    }
  end

  defp put_node_parameter(%{"properties" => properties} = parameters) when is_map(properties),
    do: Map.put(parameters, "properties", Map.put(properties, "node", @node_parameter))

  defp put_node_parameter(parameters), do: parameters

  defp selector(params) when is_map(params) do
    case Map.get(params, "node") do
      nil -> :local
      node when is_binary(node) -> classify(String.trim(node))
      _ -> {:error, "node must be a string"}
    end
  end

  defp selector(_params), do: :local

  defp classify(node) when node in ["", "local"], do: :local
  defp classify(node), do: {:remote, node}

  # ── Remote dispatch ──────────────────────────────────────────────────────

  defp run_remote(tool, selector, params, tool_call_id, signal, opts) do
    started = System.monotonic_time(:millisecond)

    result =
      with {:ok, node} <- resolve(selector),
           :ok <- supports?(node, tool),
           {:ok, args} <- request(tool, params, tool_call_id, opts) do
        if AbortSignal.aborted?(signal) do
          not_run(node.name, "the call was cancelled before it was sent")
        else
          dispatch(node, tool, args, signal)
        end
      end

    case result do
      %AgentToolResult{} = result ->
        put_details(result, %{duration_ms: System.monotonic_time(:millisecond) - started})

      {:error, message} ->
        error_result(message, %{node: selector, outcome: :not_started, reason: :skipped})
    end
  end

  defp resolve(selector) do
    case NodeRegistry.resolve(selector) do
      {:ok, node} -> {:ok, node}
      {:error, _} -> {:error, "No connected node named \"#{selector}\". #{connected_hint()}"}
    end
  catch
    :exit, _ -> {:error, "Node routing is unavailable in this runtime."}
  end

  defp connected_hint do
    case Enum.map(NodeRegistry.list(), & &1.name) do
      [] -> "No nodes are connected."
      names -> "Connected nodes: #{Enum.join(Enum.sort(names), ", ")}."
    end
  end

  defp supports?(node, tool) do
    case node.metadata |> capabilities() |> Map.get(@method) do
      %{"version" => @version, "tools" => tools} when is_list(tools) ->
        if tool in tools,
          do: :ok,
          else: {:error, "Node \"#{node.name}\" does not offer the #{tool} tool."}

      _ ->
        {:error,
         "Node \"#{node.name}\" cannot run single tool calls; update Lemon on that machine."}
    end
  end

  defp capabilities(%{capabilities: capabilities}) when is_map(capabilities), do: capabilities
  defp capabilities(%{"capabilities" => capabilities}) when is_map(capabilities), do: capabilities
  defp capabilities(_metadata), do: %{}

  defp request(tool, params, tool_call_id, opts) do
    with {:ok, context} <- execution_context(opts),
         {:ok, context} <- ExecutionContext.for_remote(context, nil),
         {:ok, encoded} <- ExecutionContext.encode(context) do
      {:ok,
       %{
         "version" => @version,
         "tool" => tool,
         "arguments" => params,
         "toolCallId" => to_string(tool_call_id),
         "sessionId" => session_id(opts),
         "runId" => context.run_id,
         "toolIntent" => CodingAgent.ToolIntent.controller_receipt(tool_call_id),
         "executionContext" => encoded
       }}
    else
      {:error, reason} -> {:error, "Cannot route this call: #{inspect(reason)}"}
    end
  end

  defp execution_context(opts) do
    case Keyword.get(opts, :execution_context) do
      %ExecutionContext{} = context ->
        {:ok, context}

      _ ->
        ExecutionContext.new(
          run_id: Keyword.get(opts, :run_id) || "node-tool-#{System.unique_integer([:positive])}",
          tool_policy: Keyword.get(opts, :tool_policy),
          provenance: %{origin: "node_tool"}
        )
    end
  end

  defp session_id(opts) do
    case Keyword.get(opts, :session_id) do
      id when is_binary(id) and id != "" -> id
      _ -> "cwd-" <> Base.url_encode64(:crypto.hash(:sha256, Keyword.get(opts, :cwd, "")))
    end
  end

  # Only a definite admission refusal means nothing ran. A broker call that
  # exits after it may have dispatched, a broker restart, a lost deadline or a
  # cancellation are all unknown outcomes.
  defp dispatch(node, tool, args, signal) do
    timeout_ms = timeout_ms(tool, args["arguments"])

    case invoke(node, args, timeout_ms) do
      {:ok, invoke_id, monitor} ->
        deadline = System.monotonic_time(:millisecond) + timeout_ms + @await_grace_ms
        AbortSignal.subscribe(signal)

        try do
          await(%{id: invoke_id, monitor: monitor, deadline: deadline}, node, tool, signal)
        after
          Process.demonitor(monitor, [:flush])
          AbortSignal.unsubscribe(signal)
        end

      {:error, reason} ->
        not_run(node.name, "the node could not accept it (#{format_reason(reason)})")

      :unknown ->
        unknown(node.name, "the routing service did not confirm whether it dispatched the call")
    end
  end

  defp invoke(node, args, timeout_ms) do
    case Process.whereis(NodeRegistry) do
      nil ->
        {:error, :routing_unavailable}

      registry ->
        monitor = Process.monitor(registry)

        case NodeRegistry.invoke_node(node.id, @method, args,
               timeout_ms: timeout_ms,
               expected_pid: node.pid,
               expected_generation: node.generation
             ) do
          {:ok, invoke_id} ->
            {:ok, invoke_id, monitor}

          {:error, reason} ->
            Process.demonitor(monitor, [:flush])
            {:error, reason}
        end
    end
  catch
    :exit, {:noproc, _} -> {:error, :routing_unavailable}
    :exit, _ -> :unknown
  end

  defp await(%{id: invoke_id, monitor: monitor} = pending, node, tool, signal) do
    if AbortSignal.aborted?(signal) do
      cancelled(invoke_id, node)
    else
      receive do
        {:lemon_node_result, ^invoke_id, {:ok, result}} ->
          completed(result, node, tool)

        {:lemon_node_result, ^invoke_id, {:error, reason}} ->
          failed(reason, node, tool)

        {:DOWN, ^monitor, :process, _pid, _reason} ->
          unknown(node.name, "the routing service restarted while the call was running")

        {:lemon_abort, ^signal, :abort} ->
          cancelled(invoke_id, node)

        {:lemon_abort, ^signal, :redirect} ->
          await(pending, node, tool, signal)
      after
        max(pending.deadline - System.monotonic_time(:millisecond), 0) ->
          cancel(invoke_id)
          unknown(node.name, "no result arrived before the routing deadline; it was cancelled")
      end
    end
  end

  defp cancelled(invoke_id, node) do
    cancel(invoke_id)

    unknown(
      node.name,
      "the call was cancelled while it ran on the node; it may have partly taken effect"
    )
  end

  defp cancel(invoke_id) do
    NodeRegistry.cancel(invoke_id, :aborted)

    receive do
      {:lemon_node_result, ^invoke_id, _} -> :ok
    after
      0 -> :ok
    end
  catch
    :exit, _ -> :ok
  end

  defp completed(result, node, tool) do
    case decode_result(result) do
      {:ok, %AgentToolResult{} = decoded} ->
        decoded
        |> note_node_paths(node.name)
        |> put_details(%{
          node: node.name,
          node_id: node.id,
          outcome: decoded.details[:outcome] || "completed"
        })
        |> ToolResultTrust.untrusted(source(tool))

      {:error, _} ->
        unknown(node.name, "the node returned a malformed result")
    end
  end

  # Spilled output (artifact handles, saved full-output files) lives on the
  # node; say so, or a later `read` without `node` looks on the controller.
  defp note_node_paths(%AgentToolResult{content: content} = result, node) do
    spilled? =
      Enum.any?(content, fn
        %TextContent{text: text} ->
          String.contains?(text, "artifact://") or String.contains?(text, "Full output saved to")

        _ ->
          false
      end)

    if spilled? do
      note = %TextContent{
        text:
          "[Saved output and artifact:// handles above are on node \"#{node}\"; read them with node: \"#{node}\".]"
      }

      %{result | content: content ++ [note]}
    else
      result
    end
  end

  defp failed({:remote, error}, node, _tool) do
    case remote_reason(error) do
      "result_payload_limit_exceeded" ->
        error_result(
          "The call ran on node \"#{node.name}\" but its result was too large to return. " <>
            "Narrow the output (for example with head, offset/limit or a smaller pattern).",
          %{node: node.name, outcome: "completed"}
        )

      reason when reason in ["tool_failed", "process_outcome_unknown"] ->
        unknown(node.name, "the node failed while running it (#{reason})")

      reason ->
        not_run(node.name, "the node refused it (#{reason})")
    end
  end

  defp failed(:timeout, node, _tool),
    do: unknown(node.name, "no result arrived before the routing deadline; it was cancelled")

  defp failed({:node_disconnected, _}, node, _tool),
    do: unknown(node.name, "the connection to the node dropped while the call was running")

  defp failed(:aborted, node, _tool),
    do: unknown(node.name, "the call was cancelled while it ran on the node")

  defp failed(reason, node, _tool),
    do: unknown(node.name, "the call ended without a result (#{format_reason(reason)})")

  defp remote_reason(error) when is_binary(error), do: error
  defp remote_reason(error) when is_atom(error), do: Atom.to_string(error)

  defp remote_reason(%{} = error),
    do: remote_reason(error["code"] || error["reason"] || error["message"] || "error")

  defp remote_reason(error), do: inspect(error, limit: 5)

  defp format_reason({:invalid_payload, {:max_bytes, _}}),
    do: "its arguments exceed the 1 MiB transport limit; split the content into smaller calls"

  defp format_reason({kind, _detail}) when is_atom(kind), do: Atom.to_string(kind)
  defp format_reason(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp format_reason(reason), do: inspect(reason, limit: 5)

  defp not_run(node, why) do
    error_result("Not run on node \"#{node}\": #{why}. Nothing ran and nothing was retried.", %{
      node: node,
      outcome: :not_started,
      reason: :skipped
    })
  end

  defp unknown(node, why) do
    error_result(
      "Outcome unknown on node \"#{node}\": #{why}. The call may have taken effect; it was " <>
        "not retried. Check the node's state before repeating it.",
      %{node: node, outcome: :unknown, reason: :interrupted}
    )
  end

  defp error_result(text, details) do
    %AgentToolResult{content: [%TextContent{text: text}], details: details, is_error: true}
  end

  defp put_details(%AgentToolResult{details: details} = result, extra) when is_map(details),
    do: %{result | details: Map.merge(details, extra)}

  defp put_details(%AgentToolResult{details: nil} = result, extra),
    do: %{result | details: extra}

  defp put_details(%AgentToolResult{details: details} = result, extra),
    do: %{result | details: Map.put(extra, :value, details)}

  defp source(tool) when tool in ["read", "write", "edit"], do: :local_file
  defp source(tool) when tool in ["ls", "grep", "find"], do: :local_search
  defp source(_tool), do: :shell

  @doc false
  def timeout_ms(tool, arguments) do
    requested =
      case {tool, arguments} do
        {"bash", %{"timeout" => ms}} when is_number(ms) and ms > 0 -> trunc(ms)
        {"bash", _} -> 120_000
        {"eval", %{"timeout" => s}} when is_number(s) and s == 0 -> @max_timeout_ms
        {"eval", %{"timeout" => s}} when is_number(s) and s > 0 -> trunc(s * 1000)
        {"eval", _} -> 30_000
        _ -> @default_timeout_ms - @margin_ms
      end

    min(requested + @margin_ms, @max_timeout_ms)
  end

  # ── Result codec ─────────────────────────────────────────────────────────

  @doc "Encodes a tool result for `coding_agent.tool` transport."
  @spec encode_result(term()) :: map()
  def encode_result({:ok, %AgentToolResult{} = result}), do: encode_result(result)

  def encode_result({:error, reason}) do
    encode_result(%AgentToolResult{
      content: [%TextContent{text: error_text(reason)}],
      is_error: true
    })
  end

  def encode_result(%AgentToolResult{} = result) do
    %{
      "content" => Enum.flat_map(List.wrap(result.content), &encode_content/1),
      "isError" => result.is_error == true,
      "details" => encode_details(result.details)
    }
  end

  def encode_result(other) do
    encode_result(%AgentToolResult{
      content: [%TextContent{text: "Unexpected tool result: #{inspect(other, limit: 10)}"}],
      is_error: true
    })
  end

  defp error_text(reason) when is_binary(reason), do: reason
  defp error_text(reason), do: inspect(reason, limit: 10)

  defp encode_content(%TextContent{text: text}) when is_binary(text),
    do: [%{"type" => "text", "text" => text}]

  defp encode_content(%ImageContent{data: data, mime_type: mime_type})
       when is_binary(data) and is_binary(mime_type),
       do: [%{"type" => "image", "data" => data, "mimeType" => mime_type}]

  defp encode_content(_content), do: []

  # Tool-supplied metadata cannot attest a trust transform; the controller
  # re-marks routed results itself.
  defp encode_details(details) when is_map(details) do
    safe =
      details
      |> Map.drop([:trust_boundary, "trust_boundary"])
      |> CodingAgent.ExecutionNode.Codec.json_safe()

    case Jason.encode(safe) do
      {:ok, json} when byte_size(json) <= @max_details_bytes -> safe
      _ -> nil
    end
  end

  defp encode_details(_details), do: nil

  @doc "Decodes a `coding_agent.tool` result into an `AgentToolResult`."
  @spec decode_result(term()) :: {:ok, AgentToolResult.t()} | {:error, :invalid_result}
  def decode_result(%{"content" => content, "isError" => is_error} = result)
      when is_list(content) and is_boolean(is_error) do
    with {:ok, blocks} <- decode_content(content, []) do
      details =
        case result["details"] do
          details when is_map(details) ->
            details
            |> Map.drop(["trust_boundary"])
            |> decode_interruption_details()

          _ ->
            nil
        end

      {:ok, %AgentToolResult{content: blocks, details: details, is_error: is_error}}
    end
  end

  def decode_result(_result), do: {:error, :invalid_result}

  # Normalize only the closed interruption vocabulary at the JSON boundary.
  # Other tool-specific details retain their wire representation.
  defp decode_interruption_details(details) do
    Enum.reduce(
      [
        {:outcome, %{"unknown" => :unknown, "not_started" => :not_started}},
        {:reason,
         %{
           "aborted" => :aborted,
           "timeout" => :timeout,
           "crashed" => :crashed,
           "interrupted" => :interrupted,
           "skipped" => :skipped
         }}
      ],
      details,
      fn {key, values}, acc ->
        wire_key = Atom.to_string(key)

        case Map.fetch(values, acc[wire_key]) do
          {:ok, value} -> acc |> Map.delete(wire_key) |> Map.put(key, value)
          :error -> acc
        end
      end
    )
  end

  defp decode_content([], acc), do: {:ok, Enum.reverse(acc)}

  defp decode_content([%{"type" => "text", "text" => text} | rest], acc) when is_binary(text),
    do: decode_content(rest, [%TextContent{text: text} | acc])

  defp decode_content([%{"type" => "image", "data" => data, "mimeType" => mime} | rest], acc)
       when is_binary(data) and is_binary(mime),
       do: decode_content(rest, [%ImageContent{data: data, mime_type: mime} | acc])

  defp decode_content(_content, _acc), do: {:error, :invalid_result}
end
