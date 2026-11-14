defmodule LemonMCP do
  @moduledoc """
  LemonMCP is Lemon's Model Context Protocol (MCP) client library.

  MCP is an open protocol that enables seamless integration between LLM applications
  and external data sources and tools. This library connects Lemon to external MCP
  servers; `LemonSkills.McpSource` loads it to expose their tools to agents.

  ## Components

  - `LemonMCP.Protocol` - MCP message types and JSON-RPC handling
  - `LemonMCP.Transport.Stdio` - Stdio transport for MCP servers
  - `LemonMCP.Client` - GenServer client for stdio MCP servers
  - `LemonMCP.Client.HTTP` - Streamable HTTP client
  - `LemonMCP.Client.SSE` - Legacy HTTP+SSE client
  - `LemonMCP.Sampling` - Policy-gated handling of server `sampling/createMessage` requests

  ## Quick Start

      # Start a client connection to an MCP server
      {:ok, client} = LemonMCP.Client.start_link(
        command: "npx",
        args: ["-y", "@modelcontextprotocol/server-filesystem", "/path/to/files"]
      )

      # List available tools
      {:ok, tools} = LemonMCP.Client.list_tools(client)

      # Call a tool
      {:ok, result} = LemonMCP.Client.call_tool(client, "read_file", %{"path" => "/path/to/file.txt"})

  ## Protocol Version

  This implementation targets MCP protocol version "2024-11-05".
  """
end
