defmodule LemonMCP do
  @moduledoc """
  LemonMCP provides a client implementation for the Model Context Protocol (MCP).

  MCP is an open protocol that enables seamless integration between LLM applications
  and external data sources and tools. This library provides:

  - `LemonMCP.Protocol` - MCP message types and JSON-RPC handling
  - `LemonMCP.Transport.Stdio` - Stdio transport for MCP servers
  - `LemonMCP.Client` - GenServer client for managing MCP connections

  ## Basic Usage

  Start a client connection to an MCP server:

      {:ok, client} = LemonMCP.Client.start_link(
        command: "npx",
        args: ["-y", "@modelcontextprotocol/server-filesystem", "/path/to/files"]
      )

  List available tools:

      {:ok, tools} = LemonMCP.Client.list_tools(client)

  Call a tool:

      {:ok, result} = LemonMCP.Client.call_tool(client, "read_file", %{"path" => "/path/to/file.txt"})

  ## Protocol Version

  This implementation targets MCP protocol version "2024-11-05".
  """

  @doc """
  Returns the supported MCP protocol version.
  """
  @spec protocol_version() :: String.t()
  def protocol_version, do: "2024-11-05"
end
