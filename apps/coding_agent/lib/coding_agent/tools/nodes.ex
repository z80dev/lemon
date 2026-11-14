defmodule CodingAgent.Tools.Nodes do
  @moduledoc """
  `nodes` tool: lists the named execution nodes connected to this controller.

  Its presence in a session's tool set is also the authority for node routing:
  routable built-ins gain a `node` argument only when `nodes` is allowed (see
  `CodingAgent.NodeTools`). Each node's live host summary comes from
  `node.host.info`, requested concurrently with a short deadline; a node that
  does not answer is still listed.
  """

  alias CodingAgent.NodeTools
  alias LemonAgent.Security.ToolResultTrust
  alias LemonAgent.Types.{AgentTool, AgentToolResult}
  alias LemonAi.Types.TextContent
  alias LemonCore.NodeRegistry

  @info_timeout_ms 5_000

  @spec tool(String.t(), keyword()) :: AgentTool.t()
  def tool(_cwd, _opts \\ []) do
    %AgentTool{
      name: "nodes",
      label: "Nodes",
      description:
        "List the named machines (nodes) connected to Lemon. Routable tools (" <>
          Enum.join(NodeTools.routable(), ", ") <>
          ") accept `node: \"<name>\"` to run that one call on the machine, with its files, " <>
          "shell and network; omit `node` to run here. In eval, `tools.<name>({..., node})` " <>
          "inside one cell fans calls out to several machines at once. A call cut off by a " <>
          "dropped connection is reported as an unknown outcome and never retried.",
      parameters: %{"type" => "object", "properties" => %{}, "required" => []},
      execute: &execute/4
    }
  end

  @doc false
  def execute(_tool_call_id, _params, _signal, _on_update) do
    nodes =
      NodeRegistry.list()
      |> Task.async_stream(&describe/1,
        timeout: @info_timeout_ms + 1_000,
        on_timeout: :kill_task,
        max_concurrency: 16
      )
      |> Enum.flat_map(fn
        {:ok, node} -> [node]
        _ -> []
      end)

    %AgentToolResult{
      content: [%TextContent{text: render(nodes)}],
      details: %{local: local_host(), nodes: nodes}
    }
    |> ToolResultTrust.untrusted(:api)
  catch
    :exit, _ ->
      %AgentToolResult{
        content: [%TextContent{text: "Node routing is unavailable in this runtime."}],
        is_error: true
      }
  end

  defp describe(node) do
    descriptor = node.metadata |> capabilities() |> Map.get(NodeTools.method())

    tools =
      case descriptor do
        %{"version" => 1, "tools" => tools} when is_list(tools) -> tools
        _ -> []
      end

    %{
      name: node.name,
      id: node.id,
      connected_at_ms: node.connected_at_ms,
      tools: tools,
      host: host_info(node)
    }
  end

  defp capabilities(%{capabilities: capabilities}) when is_map(capabilities), do: capabilities
  defp capabilities(%{"capabilities" => capabilities}) when is_map(capabilities), do: capabilities
  defp capabilities(_metadata), do: %{}

  defp host_info(node) do
    case NodeRegistry.invoke_node(node.id, "node.host.info", %{},
           timeout_ms: @info_timeout_ms,
           expected_pid: node.pid,
           expected_generation: node.generation
         ) do
      {:ok, invoke_id} ->
        receive do
          {:lemon_node_result, ^invoke_id, {:ok, info}} when is_map(info) ->
            Map.take(info, ~w(hostname os osVersion arch cpuCount memTotalBytes defaultCwd user
                              lemonVersion))

          {:lemon_node_result, ^invoke_id, _} ->
            nil
        after
          @info_timeout_ms + 500 -> nil
        end

      {:error, _} ->
        nil
    end
  end

  defp local_host do
    {:ok, hostname} = :inet.gethostname()
    %{hostname: List.to_string(hostname)}
  end

  defp render([]) do
    "No nodes are connected. Calls without `node` run here (#{local_host().hostname})."
  end

  defp render(nodes) do
    lines = Enum.map(nodes, &render_node/1)

    Enum.join(
      [
        "Connected nodes (calls without `node` run here, on #{local_host().hostname}):"
        | lines
      ],
      "\n"
    )
  end

  defp render_node(node) do
    host =
      case node.host do
        %{} = info ->
          [
            info["hostname"] && "host #{info["hostname"]}",
            platform(info),
            info["cpuCount"] && "#{info["cpuCount"]} CPUs",
            gib(info["memTotalBytes"]),
            info["user"] && "user #{info["user"]}",
            info["defaultCwd"] && "cwd #{info["defaultCwd"]}",
            info["lemonVersion"] && "Lemon #{info["lemonVersion"]}"
          ]
          |> Enum.reject(&is_nil/1)
          |> Enum.join(", ")

        nil ->
          "host details unavailable"
      end

    tools =
      case node.tools do
        [] -> "cannot run tool calls (update Lemon on that machine)"
        tools -> "tools: " <> Enum.join(tools, ", ")
      end

    "- #{node.name}: #{host}; #{tools}"
  end

  defp platform(%{"os" => os, "arch" => arch}) when is_binary(os) and is_binary(arch),
    do: "#{os} #{arch}"

  defp platform(_info), do: nil

  defp gib(bytes) when is_integer(bytes) and bytes > 0,
    do: "#{Float.round(bytes / 1_073_741_824, 1)} GiB RAM"

  defp gib(_bytes), do: nil
end
