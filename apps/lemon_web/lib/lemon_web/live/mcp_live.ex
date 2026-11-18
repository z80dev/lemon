defmodule LemonWeb.McpLive do
  @moduledoc """
  MCP: the runtime's globally configured Model Context Protocol servers with
  connection status, transport, tool counts and a tool-list drawer.

  `mcp.servers.list` is a pure read; "Reconnect" calls the admin
  `mcp.servers.refresh` (async: it reloads configuration, reconnects dead
  clients and re-discovers tools). Servers are shown by configured name and a
  redacted label (executable basename / URL host) only.

  Project MCP trust (`projectTrust`) for directories that sessions have loaded
  is displayed read-only: pending or changed trust, rejected host-secret
  references and redacted previews. Granting trust stays a terminal action
  (`lemon mcp trust`); this page has no control for it.
  """

  use LemonWeb, :live_view

  import LemonWeb.KnowledgeComponents

  alias LemonWeb.Rpc

  @poll_ms 15_000

  @impl true
  def mount(_params, _session, socket) do
    _ = if connected?(socket), do: Process.send_after(self(), :poll, @poll_ms)

    {:ok,
     socket
     |> assign(
       nav: :mcp,
       page_title: "MCP · Lemon",
       query: "",
       selected: nil,
       tool_query: "",
       refreshing: false
     )
     |> load()}
  end

  @impl true
  def handle_event("search", %{"q" => q}, socket),
    do: {:noreply, assign(socket, query: String.slice(q, 0, 200))}

  def handle_event("tool_search", %{"q" => q}, socket),
    do: {:noreply, assign(socket, tool_query: String.slice(q, 0, 200))}

  def handle_event("select", %{"id" => id}, socket),
    do: {:noreply, assign(socket, selected: id, tool_query: "")}

  def handle_event("close", _params, socket), do: {:noreply, assign(socket, selected: nil)}

  def handle_event("reload", _params, socket), do: {:noreply, load(socket)}

  def handle_event("reconnect", _params, %{assigns: %{refreshing: true}} = socket),
    do: {:noreply, socket}

  def handle_event("reconnect", _params, socket) do
    {:noreply,
     socket
     |> assign(refreshing: true)
     |> start_async(:refresh, fn -> Rpc.call("mcp.servers.refresh", %{}) end)}
  end

  @impl true
  def handle_async(:refresh, {:ok, {:ok, payload}}, socket) when is_map(payload) do
    socket = socket |> assign(refreshing: false) |> apply_payload(payload)
    connected = get_in(payload, ["summary", "connected"]) || 0
    count = get_in(payload, ["summary", "count"]) || 0
    {:noreply, put_flash(socket, :info, "Reconnected: #{connected} of #{count} servers online.")}
  end

  def handle_async(:refresh, {:ok, {:error, error}}, socket),
    do: {:noreply, socket |> assign(refreshing: false) |> put_flash(:error, Rpc.message(error))}

  def handle_async(:refresh, _exit, socket) do
    {:noreply,
     socket
     |> assign(refreshing: false)
     |> load()
     |> put_flash(:error, "Reconnect did not report back; the list shows the current state.")}
  end

  @impl true
  def handle_info(:poll, socket) do
    Process.send_after(self(), :poll, @poll_ms)
    {:noreply, if(socket.assigns.refreshing, do: socket, else: load(socket))}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  defp load(socket) do
    case Rpc.call("mcp.servers.list", %{}) do
      {:ok, payload} when is_map(payload) ->
        apply_payload(socket, payload)

      {:error, error} ->
        assign(socket,
          state: {:error, Rpc.message(error)},
          servers: [],
          summary: %{},
          project_trust: []
        )
    end
  end

  defp apply_payload(socket, payload) do
    servers = payload |> Map.get("servers", []) |> List.wrap() |> Enum.filter(&is_map/1)

    project_trust =
      payload |> Map.get("projectTrust", []) |> List.wrap() |> Enum.filter(&is_map/1)

    state =
      cond do
        payload["available"] == false -> :disabled
        payload["loaded"] == false -> :not_loaded
        true -> :ok
      end

    assign(socket,
      state: state,
      servers: servers,
      summary: payload["summary"] || %{},
      project_trust: project_trust
    )
  end

  defp trust_tone("trusted"), do: "success"
  defp trust_tone("changed"), do: "danger"
  defp trust_tone(_), do: "warning"

  defp trust_title("trusted"), do: "Trusted project MCP files"
  defp trust_title("changed"), do: "Project MCP files changed since they were trusted"
  defp trust_title(_), do: "Untrusted project MCP files"

  defp list(value), do: value |> List.wrap() |> Enum.filter(&is_map/1)
  defp text_list(value), do: value |> List.wrap() |> Enum.filter(&is_binary/1)

  # ── View helpers ─────────────────────────────────────────────────────────

  defp visible(servers, query) do
    q = String.downcase(String.trim(query))

    if q == "" do
      servers
    else
      Enum.filter(servers, fn server ->
        Enum.any?([server["name"], server["label"], server["transport"]], &contains?(&1, q)) or
          Enum.any?(server["tools"] || [], fn tool ->
            contains?(tool["remoteName"], q) or contains?(tool["name"], q)
          end)
      end)
    end
  end

  defp visible_tools(tools, query) do
    q = String.downcase(String.trim(query))

    if q == "",
      do: tools,
      else:
        Enum.filter(tools, fn t ->
          Enum.any?([t["remoteName"], t["name"], t["description"]], &contains?(&1, q))
        end)
  end

  defp contains?(value, q), do: is_binary(value) and String.contains?(String.downcase(value), q)

  defp status_tone("connected"), do: "success"
  defp status_tone("failed"), do: "danger"
  defp status_tone("disconnected"), do: "warning"
  defp status_tone(_), do: "neutral"

  defp status_label("connected"), do: "Connected"
  defp status_label("failed"), do: "Failed"
  defp status_label("disconnected"), do: "Disconnected"
  defp status_label("pending"), do: "Not connected yet"
  defp status_label(_), do: "Unknown"

  defp error_text("connection_failed"),
    do: "Could not start or reach the server (check the command or URL and credentials)."

  defp error_text("discovery_failed"), do: "Connected, but listing its tools failed."

  defp error_text("disconnected"),
    do: "The client disconnected; it reconnects on the next refresh."

  defp error_text("error"), do: "The server reported an error."
  defp error_text(_), do: nil

  defp transport_label("stdio"), do: "stdio"
  defp transport_label("http"), do: "HTTP"
  defp transport_label("sse"), do: "SSE"
  defp transport_label(other), do: other || "—"

  defp display_name(server), do: server["name"] || server["label"] || "Unnamed server"

  # ── Render ───────────────────────────────────────────────────────────────

  @impl true
  def render(assigns) do
    assigns =
      assign(assigns,
        shown: visible(assigns.servers, assigns.query),
        server: assigns.selected && Enum.find(assigns.servers, &(&1["id"] == assigns.selected))
      )

    ~H"""
    <.page>
      <.page_header
        title="MCP"
        icon="plug"
        subtitle="Model Context Protocol servers that give agents external tools."
      >
        <:actions>
          <.button
            size="sm"
            icon="refresh"
            mutation
            loading={@refreshing}
            disabled={match?({:error, _}, @state) or @state == :disabled}
            phx-click="reconnect"
          >
            {if @refreshing, do: "Reconnecting…", else: "Reconnect"}
          </.button>
        </:actions>
      </.page_header>

      <.callout :if={match?({:error, _}, @state)} tone="danger" title="MCP status is unavailable" class="mb-4">
        {elem(@state, 1)}
        <:actions><.button size="sm" phx-click="reload">Retry</.button></:actions>
      </.callout>

      <.callout :if={@state == :disabled} tone="neutral" title="MCP is disabled in this runtime" class="mb-4">
        The runtime was started with MCP turned off (<code class="font-mono">LEMON_MCP_DISABLED</code>
        or <code class="font-mono">:mcp_disabled</code>) or without the MCP client library.
      </.callout>

      <div :if={@state in [:ok, :not_loaded] and @servers != []} class="mb-4 grid grid-cols-2 gap-2 sm:grid-cols-4">
        <.stat label="Servers" value={@summary["count"] || length(@servers)} icon="plug" />
        <.stat label="Connected" value={@summary["connected"] || 0} tone="success" icon="check-circle" />
        <.stat
          label="Failing"
          value={@summary["failed"] || 0}
          tone={if (@summary["failed"] || 0) > 0, do: "danger", else: "neutral"}
          icon="alert-circle"
        />
        <.stat label="Tools" value={@summary["toolCount"] || 0} icon="wrench" />
      </div>

      <.callout :if={@state == :not_loaded} tone="info" title="Not discovered yet" class="mb-4">
        The runtime has not loaded its MCP configuration yet. Reconnect to load it and connect.
      </.callout>

      <section :if={@project_trust != []} id="mcp-project-trust" class="mb-4 space-y-2">
        <.callout
          :for={entry <- @project_trust}
          tone={trust_tone(entry["trust"])}
          title={trust_title(entry["trust"])}
        >
          <p class="break-all font-mono text-2xs">{entry["project"]}</p>
          <p class="text-xs">
            Files: <span class="font-mono">{Enum.join(text_list(entry["files"]), ", ")}</span>
          </p>
          <ul :if={list(entry["servers"]) != []} class="mt-1 space-y-0.5 text-xs">
            <li :for={server <- list(entry["servers"])}>
              <span class="font-semibold">{server["name"]}</span>
              · {server["provider"]} · {transport_label(server["transport"])} ·
              <code class="break-all font-mono">{server["preview"]}</code>
            </li>
          </ul>
          <ul :if={list(entry["rejected"]) != []} class="mt-1 space-y-0.5 text-xs">
            <li :for={rejected <- list(entry["rejected"])}>
              Rejected <span class="font-semibold">{rejected["server"]}</span>
              ({rejected["provider"]}): references host values or secrets
              (<span class="font-mono">{Enum.join(text_list(rejected["keys"]), ", ")}</span>)
            </li>
          </ul>
          <p :if={entry["trust"] != "trusted"} class="mt-1 text-xs text-muted">
            Nothing from these files starts until the operator reviews and trusts them from
            a terminal on the runtime host with <code class="font-mono">lemon mcp trust</code>
            in that directory. This page never grants trust.
          </p>
        </.callout>
      </section>

      <div :if={@state == :ok and @servers == []} id="mcp-empty">
        <.empty_state
          icon="plug"
          title="No MCP servers configured"
          description="MCP servers add external tools (filesystems, git, issue trackers, browsers) to every agent session."
        />
        <.card class="mt-4">
          <:header>Add a server</:header>
          <div class="space-y-3 text-[13px] text-fg">
            <p>
              Servers live in <code class="font-mono">~/.lemon/agent/mcp.json</code>
              (global) or <code class="font-mono">.lemon/mcp.json</code>
              (per project). Add one from a terminal on the runtime host:
            </p>
            <.code_block
              id="mcp-add-example"
              language="bash"
              code={"lemon mcp add filesystem --global --stdio npx -- -y @modelcontextprotocol/server-filesystem ~/notes\nlemon mcp add remote --global --http https://example.com/mcp --header 'Authorization=Bearer TOKEN'\nlemon mcp test filesystem --global"}
            />
            <p class="text-xs text-muted">
              New sessions read the configuration automatically; press Reconnect here to load it now.
              This page lists global servers; project servers load with sessions in that project.
              Reference: <code class="font-mono">docs/skills.md</code> → “MCP (Model Context Protocol) Server Integration”.
            </p>
          </div>
        </.card>
      </div>

      <div :if={@state in [:ok, :not_loaded] and @servers != []}>
        <div class="mb-3 flex flex-wrap items-center gap-2">
          <.search_field
            id="mcp-search"
            event="search"
            value={@query}
            placeholder="Search servers and tools"
            label="Search MCP servers and tools"
            class="w-full sm:w-80"
          />
          <span class="ml-auto text-xs text-subtle">Global servers · auto-refresh every 15s</span>
        </div>

        <.empty_state :if={@shown == []} icon="search" title="No servers or tools match" />

        <ul :if={@shown != []} id="mcp-servers" role="list" class="grid gap-3 md:grid-cols-2">
          <li :for={server <- @shown} id={"mcp-server-#{server["id"]}"}>
            <button
              type="button"
              phx-click="select"
              phx-value-id={server["id"]}
              class="card flex h-full w-full flex-col gap-3 p-4 text-left transition-colors hover:border-line-strong focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-ring/40"
              aria-label={"Show tools for #{display_name(server)}"}
            >
              <div class="flex w-full items-start gap-3">
                <span class="mt-0.5 flex h-8 w-8 shrink-0 items-center justify-center rounded-md border border-line bg-surface-2 text-muted">
                  <.icon name="plug" class="h-4 w-4" />
                </span>
                <span class="min-w-0 flex-1">
                  <span class="flex items-center gap-2">
                    <.status_dot tone={status_tone(server["status"])} pulse={server["status"] == "connected"} />
                    <span class="truncate text-[13px] font-semibold text-fg">{display_name(server)}</span>
                  </span>
                  <span class="mt-0.5 block truncate font-mono text-2xs text-subtle">
                    {transport_label(server["transport"])}<span :if={server["label"] && server["name"]}> · {server["label"]}</span>
                  </span>
                </span>
                <.badge tone={status_tone(server["status"])}>{status_label(server["status"])}</.badge>
              </div>
              <p :if={error_text(server["errorClass"])} class="text-xs text-danger">
                {error_text(server["errorClass"])}
              </p>
              <div class="mt-auto flex flex-wrap items-center gap-x-4 gap-y-1 text-xs text-muted">
                <span class="inline-flex items-center gap-1">
                  <.icon name="wrench" class="h-3.5 w-3.5" />
                  <span class="tabular-nums text-fg">{server["toolCount"] || 0}</span> tools
                </span>
                <span :if={(server["resourceCount"] || 0) > 0} class="tabular-nums">
                  {server["resourceCount"]} {if server["resourceCount"] == 1, do: "resource", else: "resources"}
                </span>
                <span :if={(server["promptCount"] || 0) > 0} class="tabular-nums">
                  {server["promptCount"]} {if server["promptCount"] == 1, do: "prompt", else: "prompts"}
                </span>
                <span class="ml-auto">
                  <.badge tone={if server["approval"] == "always", do: "warning", else: "neutral"} icon="shield-check">
                    {if server["approval"] == "always", do: "Approval required", else: "No approval"}
                  </.badge>
                </span>
              </div>
            </button>
          </li>
        </ul>
      </div>

      <.drawer
        :if={@server}
        id="mcp-drawer"
        show
        title={display_name(@server)}
        description={"#{transport_label(@server["transport"])} · #{status_label(@server["status"])}"}
        width="sm:max-w-lg"
        on_cancel={JS.push("close")}
      >
        <.server_details server={@server} tool_query={@tool_query} />
      </.drawer>
    </.page>
    """
  end

  attr(:server, :map, required: true)
  attr(:tool_query, :string, required: true)

  defp server_details(assigns) do
    tools = assigns.server["tools"] || []
    assigns = assign(assigns, tools: tools, shown_tools: visible_tools(tools, assigns.tool_query))

    ~H"""
    <div class="space-y-5">
      <.callout :if={error_text(@server["errorClass"])} tone="danger" title={status_label(@server["status"])}>
        {error_text(@server["errorClass"])}
      </.callout>

      <.key_value>
        <:item label="Name">{@server["name"] || "—"}</:item>
        <:item label="Endpoint"><span class="font-mono text-xs">{@server["label"] || "—"}</span></:item>
        <:item label="Transport">{transport_label(@server["transport"])}</:item>
        <:item label="Approval">
          {if @server["approval"] == "always", do: "Every call asks for approval", else: "Not required by MCP config"}
        </:item>
        <:item label="Capabilities">
          {@server["toolCount"] || 0} tools · {@server["resourceCount"] || 0} resources · {@server["promptCount"] || 0} prompts
        </:item>
      </.key_value>

      <div>
        <div class="mb-2 flex items-center justify-between gap-2">
          <h3 class="text-2xs font-semibold uppercase tracking-wide text-subtle">Published tools</h3>
          <span class="text-xs text-subtle">{length(@tools)}</span>
        </div>
        <form :if={length(@tools) > 6} id="mcp-tool-search-form" phx-change="tool_search" class="mb-2">
          <label for="mcp-tool-search" class="sr-only">Filter tools</label>
          <input
            id="mcp-tool-search"
            name="q"
            type="search"
            value={@tool_query}
            placeholder="Filter tools"
            class="input h-8"
            phx-debounce="120"
            autocomplete="off"
          />
        </form>
        <p :if={@tools == []} class="text-[13px] text-muted">
          {if @server["status"] == "connected", do: "This server publishes no tools.", else: "Tools appear once the server connects."}
        </p>
        <ul :if={@tools != []} role="list" class="divide-y divide-line rounded-lg border border-line">
          <li :for={tool <- @shown_tools} class="px-3 py-2">
            <div class="flex items-center gap-2">
              <span class="truncate font-mono text-xs font-medium text-fg">{tool["remoteName"] || tool["name"]}</span>
              <.badge :if={tool["kind"] != "tool"} tone="info">{tool["kind"]}</.badge>
            </div>
            <p :if={tool["description"]} class="mt-0.5 line-clamp-2 text-xs text-muted">{tool["description"]}</p>
            <p :if={tool["remoteName"]} class="mt-0.5 truncate font-mono text-2xs text-subtle" title="Name agents see">
              {tool["name"]}
            </p>
          </li>
          <li :if={@shown_tools == []} class="px-3 py-4 text-center text-xs text-muted">No tools match.</li>
        </ul>
        <p :if={@server["toolsTruncated"]} class="mt-2 text-xs text-subtle">
          Showing the first {length(@tools)} of {@server["toolCount"]} tools.
        </p>
        <p class="mt-3 text-xs text-subtle">Tool descriptions come from the remote server and are untrusted.</p>
      </div>
    </div>
    """
  end
end
