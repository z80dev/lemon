defmodule CodingAgent.ExecutionNode.Capabilities do
  @moduledoc """
  Passive destination capability inspection. Supported machinery, configured
  access and measured OS grants are separate fields. Unknown permissions are
  never converted into denial or grant. Inspection does not prompt, launch a
  browser, take a screenshot, or enumerate credentials/session connector tools.
  """
  alias CodingAgent.ExecutionNode.Capabilities.Probe

  def get(opts \\ []) do
    probe = Keyword.get(opts, :capability_probe, Probe)
    os = Keyword.get(opts, :platform, :os.type()) |> elem(1)
    measured_at = System.system_time(:millisecond)
    cwd = Keyword.get(opts, :default_cwd, System.user_home!())
    with {:ok, catalog} <- probe.tool_names(cwd, opts) do
      items = [files(probe, catalog, opts), shell(probe, catalog), browser(probe, catalog),
        connectors(probe)] ++ desktop(os, probe, catalog)
      {:ok, %{"os" => Atom.to_string(os), "measuredAtMs" => measured_at,
        "stale" => Enum.any?(items, & &1["stale"]),
        "items" => Enum.map(items, &Map.put(&1, "measuredAtMs", measured_at))}}
    else
      _ -> {:error, :capability_inspection_unavailable}
    end
  rescue
    _ -> {:error, :capability_inspection_unavailable}
  catch
    :exit, _ -> {:error, :capability_inspection_unavailable}
  end

  defp files(probe, catalog, opts) do
    tools = select(catalog, ~w(read grep find ls write edit patch))
    executable = probe.executable("python3")
    access = if is_binary(executable), do: probe.root_access(opts), else: {:error, :not_installed}
    case {executable, access} do
      {nil, _} -> item("files", "Files", "files", false, "off", "unknown", [], "python3_not_installed")
      {_, {:ok, read, write}} ->
        level = cond do
          read and write and Enum.any?(tools, &(&1 in ~w(write edit patch))) -> "read_interact"
          read and Enum.any?(tools, &(&1 in ~w(read grep find ls))) -> "read_only"
          true -> "off"
        end
        grant = if read or write, do: "not_required", else: "denied"
        reason = if level == "off", do: "filesystem_access_disabled_or_denied", else: "policy_roots_measured"
        item("files", "Files", "files", true, level, grant, tools, reason)
      _ -> item("files", "Files", "files", true, "off", "unknown", tools, "policy_root_unavailable", true)
    end
  end

  defp shell(probe, catalog) do
    tools = select(catalog, ~w(bash bash_output kill_process lsp_diagnostics))
    supported = is_binary(probe.executable("python3")) and probe.shell_available?()
    level = if supported and "bash" in tools, do: "read_interact", else: "off"
    item("terminal", "Terminal", "shell", supported, level, "not_required", if(supported, do: tools, else: []),
      if(supported, do: "destination_shell_measured", else: "shell_or_python3_not_installed"))
  end

  defp browser(probe, catalog) do
    tools = Enum.filter(catalog, &String.starts_with?(&1, "browser_"))
    case probe.browser_status() do
      {:ok, status} ->
        available = field(status, :available) == true
        configured = field(status, :configured) == true or field(status, :running) == true
        level = if available and configured and tools != [], do: "read_interact", else: "off"
        supported = field(status, :supported) != false
        reason = case field(status, :inspection_reason) do
          value when value in ["browser_cdp_measured", "browser_executable_measured",
            "browser_cdp_unavailable", "browser_executable_not_installed"] -> value
          _ -> if(level == "off", do: "browser_backend_unavailable_or_not_configured", else: "browser_backend_measured")
        end
        item("browser", "Browser", "browser", supported, level, "not_required", if(supported, do: tools, else: []), reason)
      {:error, :not_installed} -> item("browser", "Browser", "browser", false, "off", "not_required", [], "browser_runtime_not_installed")
      _ -> item("browser", "Browser", "browser", true, "off", "unknown", tools, "browser_inspection_unavailable", true)
    end
  end

  defp connectors(probe) do
    # MCP endpoints and provider grants are profile/session owned. A machine
    # probe must not invent enabled tools from a global advertised method list.
    item("connectors", "Session connectors", "connector", probe.mcp_available?(), "off", "unknown", [],
      "connectors_and_permissions_are_session_scoped")
  end

  defp desktop(:darwin, probe, catalog) do
    executable = probe.executable("peekaboo")
    permissions = if executable, do: permissions(probe), else: {:error, :not_installed}
    tools = select(catalog, ["bash"])
    for {id, name, permission} <- [
      {"accessibility", "macOS Accessibility", "accessibility"},
      {"screen_recording", "macOS Screen Recording", "screenrecording"},
      {"event_synthesizing", "macOS Event Synthesizing", "eventsynthesizing"}
    ] do
      grant = case permissions do
        {:ok, grants} -> Map.get(grants, permission, "unknown")
        _ -> "unknown"
      end
      supported = is_binary(executable)
      level = cond do
        not supported or grant != "granted" or tools == [] -> "off"
        permission == "screenrecording" -> "read_only"
        true -> "read_interact"
      end
      reason = cond do
        not supported -> "peekaboo_not_installed"
        grant == "granted" -> "peekaboo_grant_measured"
        grant == "denied" -> "peekaboo_grant_denied"
        true -> "peekaboo_grant_inspection_unavailable"
      end
      item(id, name, "os_app", supported, level, grant, if(supported, do: tools, else: []), reason,
        supported and grant == "unknown")
    end ++ [item("full_disk_access", "macOS Full Disk Access", "os_app", true, "off", "unknown", [],
      "macos_has_no_nonprompting_full_disk_grant_query")]
  end

  defp desktop(:linux, probe, catalog) do
    supported = is_binary(probe.executable("xdotool"))
    measured = if supported, do: probe.command("xdotool", ["getdisplaygeometry"]), else: {:error, :not_installed}
    available = match?({:ok, _}, measured)
    tools = select(catalog, ["bash"])
    [item("x11_desktop", "X11 desktop automation", "os_app", supported,
      if(available and tools != [], do: "read_interact", else: "off"), if(available, do: "granted", else: "unknown"),
      if(supported, do: tools, else: []),
      cond do
        available -> "x11_connection_measured"
        not supported -> "xdotool_not_installed"
        true -> "display_connection_unavailable"
      end, supported and not available)]
  end
  defp desktop(_, _, _), do: [item("desktop", "Desktop automation", "os_app", false, "off", "unknown", [], "unsupported_platform")]

  defp permissions(probe) do
    with {:ok, output} <- probe.command("peekaboo", ["permissions", "status", "--json"]),
         {:ok, json} <- Jason.decode(output) do
      {:ok, permission_records(json, %{})}
    else
      _ -> {:error, :inspection_unavailable}
    end
  end

  defp permission_records(map, acc) when is_map(map) do
    name = map["permission"] || map["name"] || map["type"]
    acc = if is_binary(name), do: add_permission(acc, name, map), else: acc
    Enum.reduce(map, acc, fn {key, value}, result ->
      result = cond do
        is_boolean(value) -> add_permission(result, key, %{"granted" => value})
        is_map(value) -> add_permission(result, key, value)
        true -> result
      end
      permission_records(value, result)
    end)
  end
  defp permission_records(list, acc) when is_list(list), do: Enum.reduce(list, acc, &permission_records/2)
  defp permission_records(_, acc), do: acc

  defp add_permission(acc, name, record) do
    key = name |> String.downcase() |> String.replace(~r/[^a-z]/, "")
    key = if key in ["screenrecording", "screencapture"], do: "screenrecording", else: key
    grant = cond do
      record["granted"] == true or record["isGranted"] == true -> "granted"
      record["granted"] == false or record["isGranted"] == false -> "denied"
      record["status"] in ["granted", "authorized"] -> "granted"
      record["status"] in ["denied", "notGranted"] -> "denied"
      true -> "unknown"
    end
    if key in ["accessibility", "screenrecording", "eventsynthesizing"] and grant != "unknown" do
      case Map.fetch(acc, key) do
        :error -> Map.put(acc, key, grant)
        {:ok, ^grant} -> acc
        {:ok, _} -> Map.put(acc, key, "unknown")
      end
    else
      acc
    end
  end

  defp item(id, name, category, supported, level, grant, tools, reason, stale \\ false) do
    %{"id" => id, "name" => name, "category" => category, "supported" => supported,
      "configuredLevel" => level, "osGrant" => grant, "tools" => tools, "reason" => reason, "stale" => stale}
  end
  defp select(catalog, names), do: Enum.filter(names, &(&1 in catalog))
  defp field(map, key), do: Map.get(map, key, Map.get(map, Atom.to_string(key)))
end

defmodule CodingAgent.ExecutionNode.Capabilities.Probe do
  @moduledoc false
  alias CodingAgent.ExecutionNode.{HostCommand, HostIO}
  def executable(name), do: System.find_executable(name)
  def command(name, args), do: HostCommand.run(name, args)
  def shell_available? do
    shell = System.get_env("SHELL") || System.find_executable("sh")
    is_binary(shell) and File.regular?(shell)
  end
  def mcp_available?, do: Code.ensure_loaded?(LemonMCP.Client)
  def tool_names(cwd, opts) do
    names = CodingAgent.ToolRegistry.get_tool_tuples(cwd, include_extensions: false, include_mcp: false,
      tool_policy: Keyword.get(opts, :tool_policy)) |> Enum.map(&elem(&1, 0))
    {:ok, names}
  end
  def browser_status do
    if Code.ensure_loaded?(LemonBrowser) and function_exported?(LemonBrowser, :status, 0) do
      status = LemonBrowser.status()
      if Map.get(status, :backend, Map.get(status, "backend")) in [:local, "local"],
        do: local_browser_status(), else: {:ok, status}
    else
      {:error, :not_installed}
    end
  rescue
    _ -> {:error, :inspection_unavailable}
  catch
    :exit, _ -> {:error, :inspection_unavailable}
  end

  defp local_browser_status do
    helper = Path.join(to_string(:code.priv_dir(:coding_agent)), "node_browser_inspect.mjs")
    with {:ok, config} <- LemonBrowser.LocalServer.inspection_config(),
         {:ok, output} <- HostCommand.run("node", [helper], input: Jason.encode!(config) <> "\n"),
         {:ok, %{"supported" => supported, "available" => available, "configured" => configured,
           "running" => running, "reason" => reason}} <- Jason.decode(output),
         true <- is_boolean(supported) and is_boolean(available) and is_boolean(configured) and is_boolean(running) do
      {:ok, %{supported: supported, available: available, configured: configured,
        running: running, inspection_reason: reason}}
    else
      {:error, :not_installed} -> {:error, :not_installed}
      _ -> {:error, :inspection_unavailable}
    end
  end
  def root_access(opts) do
    roots = Keyword.get(opts, :allowed_roots, [System.user_home!()])
    Enum.reduce_while(roots, {:ok, false, false}, fn root, {:ok, read, write} ->
      with {:ok, stat} <- HostIO.handle("node.fs.stat", %{"path" => root}, opts),
           true <- is_boolean(stat["readable"]) and is_boolean(stat["writable"]) do
        {:cont, {:ok, read or stat["readable"], write or stat["writable"]}}
      else
        _ -> {:halt, {:error, :policy_root_unavailable}}
      end
    end)
  end
end
