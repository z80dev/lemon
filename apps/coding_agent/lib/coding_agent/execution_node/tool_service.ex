defmodule CodingAgent.ExecutionNode.ToolService do
  @moduledoc """
  Destination side of `coding_agent.tool`: runs one routed tool call.

  The request carries the tool name, its arguments, the controller session ID
  and the caller's execution context. Admission mirrors `coding_agent.run`:
  the context is decoded and revalidated, its run ID must match the request,
  it is intersected with this worker's capability ceiling and bound to the
  destination working directory, and the resulting policy must allow the
  tool. Approval already happened on the controller; nothing here asks again.

  The tool is built from the local built-in module and runs in the calling
  task with destination-local paths, shell and credentials. Per-session state
  (shell state, background processes, `eval` kernels, the read tracker) is
  owned by `CodingAgent.ExecutionNode.ToolSession`, keyed by a node-scoped
  form of the controller session ID.

  Effectful calls require the controller's `toolIntent` marker bound to this
  call ID. Missing/mismatched markers fail closed. Nested eval calls inherit
  that parent intent through trusted resolver state only while the eval is live;
  they never establish a second node-local journal.

  An `eval` cell running here can call this node's routable tools through its
  `tools` bridge. Such calls may name this node or omit `node`; naming another
  node fails without running, because routing belongs to the controller.
  """

  alias CodingAgent.ExecutionNode.ToolSession
  alias CodingAgent.NodeTools
  alias CodingAgent.Tools
  alias LemonAgent.Types.{AgentTool, AgentToolResult}
  alias LemonAi.Types.TextContent
  alias LemonCore.{ExecutionContext, ToolPolicy}

  @modules %{
    "bash" => Tools.Bash,
    "bash_output" => Tools.BashOutput,
    "kill_process" => Tools.KillProcess,
    "process_input" => Tools.ProcessInput,
    "read" => Tools.Read,
    "write" => Tools.Write,
    "edit" => Tools.Edit,
    "ls" => Tools.Ls,
    "grep" => Tools.Grep,
    "find" => Tools.Find,
    "eval" => Tools.Eval
  }
  @max_id_bytes 256

  @doc """
  Runs a decoded `coding_agent.tool` request.

  Options: `:default_cwd` (required), `:execution_capabilities` (destination
  ceiling, `nil` for all), `:node_name`, `:signal` (abort reference).
  Returns `{:ok, encoded_result}` or `{:error, reason}` when nothing ran.
  """
  @spec run(map(), keyword()) :: {:ok, map()} | {:error, atom()}
  def run(args, opts) when is_map(args) do
    with :ok <- refuse_if_extensions_compromised(),
         {:ok, request} <- decode(args),
         {:ok, context} <- admit(request, opts),
         {:ok, owner} <- ToolSession.acquire(scoped_session(request.session_id)) do
      try do
        cwd = Keyword.fetch!(opts, :default_cwd)
        tool_opts = tool_opts(request, context, owner, opts)

        {:ok, tool} = build(request.tool, cwd, tool_opts)

        request.tool_call_id
        |> tool.execute.(request.arguments, Keyword.get(opts, :signal), nil)
        |> NodeTools.encode_result()
        |> then(&{:ok, &1})
      after
        ToolSession.release(owner)
      end
    end
  end

  def run(_args, _opts), do: {:error, :invalid_tool_request}

  # A node worker shares the controller's fail-stop: no tool runs once an
  # extension module collision set the compromise latch.
  defp refuse_if_extensions_compromised do
    if CodingAgent.Extensions.compromised?(), do: {:error, :extensions_compromised}, else: :ok
  end

  defp decode(args) do
    with {:version, 1} <- {:version, args["version"]},
         {:tool, tool} when is_map_key(@modules, tool) <- {:tool, args["tool"]},
         arguments when is_map(arguments) <- args["arguments"],
         {:ok, call_id} <- identifier(args["toolCallId"]),
         {:ok, session_id} <- identifier(args["sessionId"]),
         {:ok, run_id} <- identifier(args["runId"]) do
      {:ok,
       %{
         tool: tool,
         arguments: arguments,
         tool_call_id: call_id,
         session_id: session_id,
         run_id: run_id,
         tool_intent: args["toolIntent"],
         context: args["executionContext"]
       }}
    else
      {:tool, tool} when is_binary(tool) -> {:error, :unsupported_tool}
      _ -> {:error, :invalid_tool_request}
    end
  end

  defp identifier(value)
       when is_binary(value) and value != "" and byte_size(value) <= @max_id_bytes do
    if String.valid?(value) and not String.contains?(value, <<0>>),
      do: {:ok, value},
      else: {:error, :invalid_tool_request}
  end

  defp identifier(_value), do: {:error, :invalid_tool_request}

  defp admit(request, opts) do
    with {:ok, context} <- decode_context(request.context),
         :ok <- same_run(context, request),
         {:ok, context} <-
           ExecutionContext.restrict_capabilities(
             context,
             Keyword.get(opts, :execution_capabilities)
           ),
         {:ok, context} <- ExecutionContext.bind_workspace(context, opts[:default_cwd]) do
      if ToolPolicy.allowed?(context.tool_policy, request.tool),
        do: {:ok, context},
        else: {:error, :forbidden}
    else
      {:error, _} -> {:error, :invalid_execution_context}
    end
  end

  defp same_run(%ExecutionContext{run_id: run_id}, %{run_id: run_id}), do: :ok
  defp same_run(_context, _request), do: {:error, :run_mismatch}

  defp decode_context(map) do
    case ExecutionContext.decode(map) do
      {:ok, context} -> {:ok, context}
      _ -> {:error, :invalid_execution_context}
    end
  end

  defp scoped_session(session_id), do: "node-tool:" <> session_id

  defp tool_opts(request, context, owner, opts) do
    available =
      Enum.filter(NodeTools.routable(), &ToolPolicy.allowed?(context.tool_policy, &1))

    base = [
      session_id: scoped_session(request.session_id),
      session_pid: owner,
      controller_tool_intent: request.tool_intent,
      tool_intent_recorder: fn _data -> {:error, :controller_intent_required} end,
      run_id: context.run_id,
      tool_policy: context.tool_policy,
      execution_context: context,
      available_tools: available,
      bash_config: %{},
      enforce_seen_lines: true
    ]

    Keyword.put(base, :tool_resolver, resolver(available, opts[:default_cwd], base, opts))
  end

  # Cells reach only this node's tools. Their mutations are covered by the
  # controller's parent eval intent only while that eval invocation is live.
  # Calls that require their own approval are still refused here.
  defp resolver(available, cwd, base_opts, opts) do
    node = Keyword.get(opts, :node_name)
    policy = Keyword.fetch!(base_opts, :tool_policy)

    base_opts =
      base_opts
      |> Keyword.put(:controller_parent_intent, Keyword.get(base_opts, :controller_tool_intent))
      |> Keyword.delete(:controller_tool_intent)

    fn name ->
      cond do
        name == "eval" ->
          {:error, "eval cannot call eval"}

        name not in available ->
          {:error, "#{name} is not available on node #{inspect(node)}"}

        true ->
          {:ok, tool} = build(name, cwd, base_opts)
          {:ok, local_only(tool, node, policy)}
      end
    end
  end

  defp local_only(%AgentTool{execute: execute, name: name} = tool, node, policy) do
    %{
      tool
      | execute: fn id, params, signal, on_update ->
          target = Map.get(params, "node")
          params = Map.delete(params, "node")

          cond do
            target not in [nil, "", "local"] and target != node ->
              refused(
                "this cell runs on node #{inspect(node)} and can only call its own tools, not " <>
                  "node #{inspect(target)}. Run the cell without node to reach several machines."
              )

            ToolPolicy.requires_approval?(policy, name, params, ToolPolicy.tier(name, params)) ->
              refused(
                "#{name} needs approval under this session's policy, and a cell running on " <>
                  "node #{inspect(node)} cannot request it. Call #{name} from the controller instead."
              )

            true ->
              execute.(id, params, signal, on_update)
          end
        end
    }
  end

  defp refused(why) do
    %AgentToolResult{
      content: [%TextContent{text: "Not run: " <> why}],
      details: %{outcome: :not_started, reason: :skipped},
      is_error: true
    }
  end

  defp build(name, cwd, tool_opts) do
    %AgentTool{} = tool = Map.fetch!(@modules, name).tool(cwd, tool_opts)
    tool = %{tool | effect: CodingAgent.ToolIntent.builtin_effect(name)}
    {:ok, CodingAgent.ToolIntent.wrap(tool, tool_opts)}
  end
end
