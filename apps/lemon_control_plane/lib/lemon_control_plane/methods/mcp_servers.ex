defmodule LemonControlPlane.Methods.McpSupport do
  @moduledoc false

  # Allowlist projection of `LemonSkills.McpSource.inventory/1`. Servers are
  # identified by configured name and a label (executable basename or URL host);
  # commands, arguments, URLs, headers, environment, OAuth settings and raw
  # transport errors never cross the wire. Remote tool names/descriptions are
  # untrusted remote metadata and are bounded.
  #
  # `projectTrust` reports, for each project directory a session has loaded,
  # pending or changed project MCP trust, rejected host-secret references and
  # bounded redacted command/URL previews from `LemonSkills.McpDiscovery`. It
  # only reads files: viewing never connects, reconnects or grants trust.

  alias LemonControlPlane.Methods.SkillsSupport
  alias LemonControlPlane.Protocol.Errors

  @max_servers 100
  @max_tools 100
  @max_description 280
  @max_projects 20

  @doc "The registered MCP source (overridable for isolated tests)."
  def source, do: Application.get_env(:lemon_control_plane, :mcp_source, LemonSkills.McpSource)

  def available?(source),
    do: Code.ensure_loaded?(LemonSkills.McpSource) and is_pid(Process.whereis(source))

  def inventory do
    source = source()

    if available?(source) do
      try do
        {:ok, project(LemonSkills.McpSource.inventory(source, []))}
      catch
        :exit, _ -> {:error, Errors.unavailable("MCP source is unavailable")}
      end
    else
      {:error, Errors.unavailable("MCP source is unavailable")}
    end
  end

  defp project(%{disabled: true}) do
    %{
      "available" => false,
      "loaded" => false,
      "servers" => [],
      "summary" => summary([], false),
      "projectTrust" => []
    }
  end

  defp project(%{servers: servers, loaded: loaded} = inventory) do
    projected = servers |> Enum.take(@max_servers) |> Enum.map(&server/1)

    %{
      "available" => true,
      "loaded" => loaded,
      "servers" => projected,
      "summary" => summary(projected, length(servers) > length(projected)),
      "projectTrust" => project_trust(Map.get(inventory, :project_scopes, []))
    }
  end

  defp project_trust(scopes) do
    scopes
    |> Enum.take(@max_projects)
    |> Enum.flat_map(fn scope ->
      case LemonSkills.McpDiscovery.project_status(scope) do
        %{trust: :none} -> []
        status -> [trust_entry(status)]
      end
    end)
  end

  defp trust_entry(status) do
    %{
      "project" => status.label,
      "trust" => Atom.to_string(status.trust),
      "files" => status.files,
      "servers" =>
        Enum.map(status.servers, &Map.take(&1, ~w(name provider transport enabled preview))),
      "rejected" =>
        for(
          %{"reason" => "host_value_reference"} = finding <- status.findings,
          do: Map.take(finding, ~w(server provider keys))
        )
    }
  end

  defp summary(servers, truncated) do
    %{
      "count" => length(servers),
      "connected" => Enum.count(servers, &(&1["status"] == "connected")),
      "failed" => Enum.count(servers, &(&1["status"] in ["failed", "disconnected"])),
      "toolCount" => servers |> Enum.map(& &1["toolCount"]) |> Enum.sum(),
      "truncated" => truncated
    }
  end

  defp server(server) do
    {status, error_class} = status(server)
    tools = Enum.take(server.tools, @max_tools)

    %{
      "id" => server.id,
      "name" => SkillsSupport.text(server.name, 64),
      "label" => SkillsSupport.text(server.label, 120),
      "transport" => Atom.to_string(server.transport),
      "status" => status,
      "errorClass" => error_class,
      "toolCount" => server.tool_count,
      "resourceCount" => server.resource_count,
      "promptCount" => server.prompt_count,
      "approval" => Atom.to_string(server.approval),
      "tools" => Enum.map(tools, &tool/1),
      "toolsTruncated" => length(server.tools) > length(tools)
    }
  end

  defp status(%{connected: true}), do: {"connected", nil}
  defp status(%{last_error: "connection failed"}), do: {"failed", "connection_failed"}
  defp status(%{last_error: "tool discovery failed"}), do: {"failed", "discovery_failed"}
  defp status(%{last_error: "client disconnected"}), do: {"disconnected", "disconnected"}
  defp status(%{last_error: nil}), do: {"pending", nil}
  defp status(_server), do: {"failed", "error"}

  defp tool(tool) do
    %{
      "name" => SkillsSupport.text(tool.name, 64),
      "remoteName" => SkillsSupport.text(tool.remote_name, 128),
      "kind" => tool_kind(tool.kind),
      "description" => SkillsSupport.text(tool.description, @max_description)
    }
  end

  defp tool_kind(:tool), do: "tool"
  defp tool_kind(kind) when kind in [:list_resources, :read_resource], do: "resource"
  defp tool_kind(kind) when kind in [:list_prompts, :get_prompt], do: "prompt"
  defp tool_kind(_), do: "utility"
end

defmodule LemonControlPlane.Methods.McpServersList do
  @moduledoc """
  Handler for the read-only `mcp.servers.list` method: the runtime's globally
  configured MCP servers with connection status, transport, counts and their
  published tools, plus `projectTrust` for loaded project directories (pending
  or changed trust, rejected host-secret references, redacted previews). Pure
  read; it never connects, reloads configuration or grants trust.
  """

  @behaviour LemonControlPlane.Method

  @impl true
  def name, do: "mcp.servers.list"

  @impl true
  def scopes, do: [:read]

  @impl true
  def handle(_params, _ctx), do: LemonControlPlane.Methods.McpSupport.inventory()
end

defmodule LemonControlPlane.Methods.McpServersRefresh do
  @moduledoc """
  Handler for `mcp.servers.refresh` (admin): reloads global MCP configuration,
  reconnects dead clients and re-discovers tools through
  `LemonSkills.McpSource.refresh/0`, then returns the fresh inventory. Async
  because connecting can wait on each server's readiness timeout. Bounded worker
  failures return `unavailable` rather than a partial success inventory.
  """

  @behaviour LemonControlPlane.Method

  alias LemonControlPlane.Methods.McpSupport
  alias LemonControlPlane.Protocol.Errors

  @impl true
  def name, do: "mcp.servers.refresh"

  @impl true
  def scopes, do: [:admin]

  @impl true
  def dispatch_mode, do: :async

  @impl true
  def handle(_params, _ctx) do
    source = McpSupport.source()

    if McpSupport.available?(source) do
      try do
        case LemonSkills.McpSource.refresh(source) do
          :ok -> McpSupport.inventory()
          {:error, _reason} -> {:error, Errors.unavailable("MCP refresh is unavailable")}
        end
      catch
        :exit, _ -> {:error, Errors.unavailable("MCP source is unavailable")}
      end
    else
      {:error, Errors.unavailable("MCP source is unavailable")}
    end
  end
end
