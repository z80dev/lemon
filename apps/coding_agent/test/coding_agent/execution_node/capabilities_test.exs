defmodule CodingAgent.ExecutionNode.CapabilitiesTest do
  use ExUnit.Case, async: true
  alias CodingAgent.ExecutionNode.Capabilities

  defmodule Probe do
    def executable(_), do: "/installed"
    def python, do: "/installed/python3"
    def shell_available?, do: true
    def root_access(_), do: {:ok, true, true}
    def browser_status, do: {:ok, %{available: true, running: true}}
    def mcp_available?, do: true
    def tool_names(_, _), do: {:ok, ~w(read write bash browser_tabs browser_click)}

    def tcc_status,
      do:
        {:ok,
         %{
           "accessibility" => "denied",
           "screenRecording" => "granted",
           "postEvent" => "denied",
           "listenEvent" => "granted",
           "fullDiskAccess" => "unknown"
         }}

    def command("peekaboo", ["permissions" | _]),
      do: raise("Capability inspection must never request Peekaboo permissions")

    def command("xdotool", ["getdisplaygeometry"]), do: {:ok, "1920 1080"}
  end

  defmodule UnknownProbe do
    defdelegate executable(name), to: Probe
    defdelegate python(), to: Probe
    defdelegate shell_available?(), to: Probe
    defdelegate root_access(opts), to: Probe
    defdelegate browser_status(), to: Probe
    defdelegate mcp_available?(), to: Probe
    defdelegate tool_names(cwd, opts), to: Probe
    def tcc_status, do: {:error, :probe_unavailable}
    def command(_, _), do: {:error, :inspection_unavailable}
  end

  defmodule AbsentProbe do
    def executable("peekaboo"), do: nil
    def executable("xdotool"), do: nil
    defdelegate executable(name), to: Probe
    defdelegate python(), to: Probe
    defdelegate shell_available?(), to: Probe
    defdelegate root_access(opts), to: Probe
    def browser_status, do: {:error, :not_installed}
    defdelegate mcp_available?(), to: Probe
    defdelegate tool_names(cwd, opts), to: Probe
    def tcc_status, do: {:error, :probe_unavailable}
    def command(_, _), do: raise("Absent capabilities must not launch inspection programs")
  end

  defmodule InvalidStatusProbe do
    defdelegate executable(name), to: Probe
    defdelegate python(), to: Probe
    defdelegate shell_available?(), to: Probe
    defdelegate root_access(opts), to: Probe
    defdelegate browser_status(), to: Probe
    defdelegate mcp_available?(), to: Probe
    defdelegate tool_names(cwd, opts), to: Probe

    defdelegate command(name, args), to: Probe
    def tcc_status, do: {:ok, %{"accessibility" => true, "fullDiskAccess" => "authorized"}}
  end

  defmodule DiagnosticsProbe do
    defdelegate executable(name), to: Probe
    defdelegate python(), to: Probe
    defdelegate shell_available?(), to: Probe
    defdelegate root_access(opts), to: Probe
    defdelegate browser_status(), to: Probe
    defdelegate mcp_available?(), to: Probe
    defdelegate command(name, args), to: Probe
    defdelegate tcc_status(), to: Probe
    defdelegate tool_names(cwd, opts), to: CodingAgent.ExecutionNode.Capabilities.Probe
  end

  defmodule NoShellDiagnosticsProbe do
    defdelegate executable(name), to: DiagnosticsProbe
    defdelegate python(), to: DiagnosticsProbe
    def shell_available?, do: false
    defdelegate root_access(opts), to: DiagnosticsProbe
    defdelegate browser_status(), to: DiagnosticsProbe
    defdelegate mcp_available?(), to: DiagnosticsProbe
    defdelegate command(name, args), to: DiagnosticsProbe
    defdelegate tcc_status(), to: DiagnosticsProbe
    defdelegate tool_names(cwd, opts), to: DiagnosticsProbe
  end

  defmodule ComputerUseProbe do
    defdelegate executable(name), to: Probe
    defdelegate python(), to: Probe
    defdelegate shell_available?(), to: Probe
    defdelegate root_access(opts), to: Probe
    defdelegate browser_status(), to: Probe
    defdelegate mcp_available?(), to: Probe
    defdelegate command(name, args), to: Probe
    defdelegate tcc_status(), to: Probe
    def tool_names(_, _), do: {:ok, ~w(read bash cua_js cua_js_reset)}
  end

  defmodule NoPythonProbe do
    defdelegate executable(name), to: Probe
    def python, do: nil
    defdelegate shell_available?(), to: Probe
    def root_access(_), do: raise("Files must not probe roots without an interpreter")
    defdelegate browser_status(), to: Probe
    defdelegate mcp_available?(), to: Probe
    defdelegate command(name, args), to: Probe
    defdelegate tcc_status(), to: Probe
    defdelegate tool_names(cwd, opts), to: Probe
  end

  test "files and terminal are unsupported when no interpreter resolves" do
    assert {:ok, snapshot} =
             Capabilities.get(platform: {:unix, :darwin}, capability_probe: NoPythonProbe)

    by_id = Map.new(snapshot["items"], &{&1["id"], &1})

    refute by_id["files"]["supported"]
    assert by_id["files"]["reason"] == "python3_not_installed"
    assert by_id["files"]["tools"] == []
    refute by_id["terminal"]["supported"]
    assert by_id["terminal"]["configuredLevel"] == "off"
    assert by_id["terminal"]["reason"] == "shell_or_python3_not_installed"
    assert by_id["terminal"]["tools"] == []
  end

  test "computer use is measured from the destination's registered tools" do
    assert {:ok, enabled} =
             Capabilities.get(platform: {:unix, :darwin}, capability_probe: ComputerUseProbe)

    item = Enum.find(enabled["items"], &(&1["id"] == "computer_use"))

    assert %{
             "category" => "os_app",
             "supported" => true,
             "configuredLevel" => "read_interact",
             "osGrant" => "unknown",
             "tools" => ["cua_js", "cua_js_reset"],
             "reason" => "computer_use_enabled_per_app_approval"
           } = item

    assert {:ok, disabled} = Capabilities.get(platform: {:unix, :darwin}, capability_probe: Probe)
    item = Enum.find(disabled["items"], &(&1["id"] == "computer_use"))

    assert %{"supported" => false, "configuredLevel" => "off", "tools" => []} = item
    assert item["reason"] == "computer_use_not_enabled"
  end

  test "measured denial, grant, and unqueryable permissions remain distinct" do
    assert {:ok, snapshot} = Capabilities.get(platform: {:unix, :darwin}, capability_probe: Probe)
    by_id = Map.new(snapshot["items"], &{&1["id"], &1})
    assert by_id["accessibility"]["osGrant"] == "denied"
    assert by_id["accessibility"]["configuredLevel"] == "off"
    assert by_id["screen_recording"]["osGrant"] == "granted"
    assert by_id["screen_recording"]["configuredLevel"] == "read_only"
    assert by_id["accessibility"]["reason"] == "macos_grant_denied"
    assert by_id["screen_recording"]["reason"] == "macos_grant_measured"
    refute by_id["accessibility"]["stale"]
    refute by_id["screen_recording"]["stale"]
    assert by_id["event_synthesizing"]["osGrant"] == "denied"
    assert by_id["full_disk_access"]["osGrant"] == "unknown"
    assert by_id["full_disk_access"]["reason"] == "macos_grant_probe_unavailable"
    assert by_id["full_disk_access"]["configuredLevel"] == "off"
    assert by_id["full_disk_access"]["tools"] == []
    assert by_id["full_disk_access"]["stale"]
    assert by_id["connectors"]["tools"] == []
    assert by_id["connectors"]["osGrant"] == "unknown"

    for item <- snapshot["items"] do
      assert item["measuredAtMs"] == snapshot["measuredAtMs"]

      assert Enum.sort(Map.keys(item)) ==
               Enum.sort(
                 ~w(id name category supported configuredLevel osGrant tools reason measuredAtMs stale)
               )
    end

    assert by_id["accessibility"]["tools"] == ["bash"]
    refute inspect(snapshot) =~ "token"
  end

  test "unavailable or invalid inspection never pretends denied or granted" do
    for probe <- [UnknownProbe, InvalidStatusProbe] do
      assert {:ok, snapshot} =
               Capabilities.get(platform: {:unix, :darwin}, capability_probe: probe)

      item = Enum.find(snapshot["items"], &(&1["id"] == "accessibility"))
      assert item["osGrant"] == "unknown"
      assert item["configuredLevel"] == "off"
      assert item["stale"]
      assert item["reason"] == "macos_grant_probe_unavailable"
      full_disk = Enum.find(snapshot["items"], &(&1["id"] == "full_disk_access"))
      assert full_disk["osGrant"] == "unknown"
      assert full_disk["configuredLevel"] == "off"
      assert full_disk["tools"] == []
      assert full_disk["stale"]

      assert full_disk["reason"] ==
               if(probe == UnknownProbe,
                 do: "macos_has_no_nonprompting_full_disk_grant_query",
                 else: "macos_grant_probe_unavailable"
               )
    end
  end

  test "absent tooling is unsupported, not a denied OS grant" do
    assert {:ok, snapshot} =
             Capabilities.get(platform: {:unix, :darwin}, capability_probe: AbsentProbe)

    item = Enum.find(snapshot["items"], &(&1["id"] == "accessibility"))
    refute item["supported"]
    assert item["osGrant"] == "unknown"
    assert item["reason"] == "peekaboo_not_installed"
    assert item["tools"] == []
  end

  test "Linux X11 grant requires an observed authenticated display connection" do
    assert {:ok, snapshot} = Capabilities.get(platform: {:unix, :linux}, capability_probe: Probe)
    item = Enum.find(snapshot["items"], &(&1["id"] == "x11_desktop"))
    assert item["osGrant"] == "granted"

    assert {:ok, snapshot} =
             Capabilities.get(platform: {:unix, :linux}, capability_probe: UnknownProbe)

    item = Enum.find(snapshot["items"], &(&1["id"] == "x11_desktop"))
    assert item["osGrant"] == "unknown"
    assert item["configuredLevel"] == "off"
  end

  test "registered diagnostics are measured as shell tooling, never baseline or unsupported machinery" do
    assert {:ok, catalog} =
             CodingAgent.ExecutionNode.Capabilities.Probe.tool_names(File.cwd!(), [])

    assert "lsp_diagnostics" in catalog

    assert {:ok, snapshot} =
             Capabilities.get(
               platform: {:unix, :linux},
               default_cwd: File.cwd!(),
               capability_probe: DiagnosticsProbe
             )

    shell = Enum.find(snapshot["items"], &(&1["id"] == "terminal"))
    files = Enum.find(snapshot["items"], &(&1["id"] == "files"))
    assert shell["configuredLevel"] == "read_interact"
    assert "lsp_diagnostics" in shell["tools"]
    refute "lsp_diagnostics" in files["tools"]

    assert {:ok, missing} = Capabilities.get(platform: {:unix, :linux}, capability_probe: Probe)

    refute missing["items"]
           |> Enum.find(&(&1["id"] == "terminal"))
           |> Map.fetch!("tools")
           |> Enum.member?("lsp_diagnostics")

    assert {:ok, unsupported} =
             Capabilities.get(
               platform: {:unix, :linux},
               default_cwd: File.cwd!(),
               capability_probe: NoShellDiagnosticsProbe
             )

    unsupported_shell = Enum.find(unsupported["items"], &(&1["id"] == "terminal"))
    refute unsupported_shell["supported"]
    assert unsupported_shell["configuredLevel"] == "off"
    assert unsupported_shell["tools"] == []
  end
end

defmodule CodingAgent.ExecutionNode.CapabilitiesTccProbeTest do
  use ExUnit.Case, async: false

  alias CodingAgent.ExecutionNode.Capabilities
  alias CodingAgent.ExecutionNode.Capabilities.Probe, as: HostProbe
  alias CodingAgent.ExecutionNode.CapabilitiesTest.Probe

  @moduletag :tmp_dir

  defmodule HelperProbe do
    defdelegate executable(name), to: Probe
    defdelegate python(), to: Probe
    defdelegate shell_available?(), to: Probe
    defdelegate root_access(opts), to: Probe
    defdelegate browser_status(), to: Probe
    defdelegate mcp_available?(), to: Probe
    defdelegate tool_names(cwd, opts), to: Probe
    defdelegate command(name, args), to: Probe
    defdelegate tcc_status(), to: HostProbe
  end

  defmodule NoPeekabooProbe do
    def executable("peekaboo"), do: nil
    defdelegate executable(name), to: HelperProbe
    defdelegate python(), to: HelperProbe
    defdelegate shell_available?(), to: HelperProbe
    defdelegate root_access(opts), to: HelperProbe
    defdelegate browser_status(), to: HelperProbe
    defdelegate mcp_available?(), to: HelperProbe
    defdelegate tool_names(cwd, opts), to: HelperProbe
    defdelegate command(name, args), to: HelperProbe
    defdelegate tcc_status(), to: HelperProbe
  end

  setup do
    previous = System.get_env("LEMON_TCC_PROBE")
    System.delete_env("LEMON_TCC_PROBE")

    on_exit(fn ->
      if previous,
        do: System.put_env("LEMON_TCC_PROBE", previous),
        else: System.delete_env("LEMON_TCC_PROBE")
    end)
  end

  test "the executable helper maps grants without invoking Peekaboo permissions", %{tmp_dir: dir} do
    status = %{
      "version" => 1,
      "accessibility" => "granted",
      "screenRecording" => "denied",
      "postEvent" => "granted",
      "listenEvent" => "denied",
      "fullDiskAccess" => "granted"
    }

    write_probe(dir, "printf '%s\\n' '#{Jason.encode!(status)}'")
    assert HostProbe.tcc_status() == {:ok, status}
    assert {:ok, snapshot} = Capabilities.get(platform: {:unix, :darwin}, capability_probe: HelperProbe)
    items = Map.new(snapshot["items"], &{&1["id"], &1})

    for id <- ~w(accessibility event_synthesizing full_disk_access) do
      assert items[id]["osGrant"] == "granted"
      assert items[id]["reason"] == "macos_grant_measured"
      refute items[id]["stale"]
    end

    assert items["accessibility"]["configuredLevel"] == "read_interact"
    assert items["event_synthesizing"]["configuredLevel"] == "read_interact"
    assert items["screen_recording"]["osGrant"] == "denied"
    assert items["screen_recording"]["reason"] == "macos_grant_denied"
    assert items["screen_recording"]["configuredLevel"] == "off"
    assert items["full_disk_access"]["configuredLevel"] == "off"
    assert items["full_disk_access"]["tools"] == []
  end

  test "Full Disk Access is measured independently of Peekaboo installation", %{tmp_dir: dir} do
    for grant <- ["granted", "denied", "unknown"] do
      status = %{"version" => 1, "fullDiskAccess" => grant, "accessibility" => "granted"}
      write_probe(dir, "printf '%s\\n' '#{Jason.encode!(status)}'")

      assert {:ok, snapshot} =
               Capabilities.get(platform: {:unix, :darwin}, capability_probe: NoPeekabooProbe)

      items = Map.new(snapshot["items"], &{&1["id"], &1})
      full_disk = items["full_disk_access"]
      assert full_disk["supported"]
      assert full_disk["osGrant"] == grant
      assert full_disk["configuredLevel"] == "off"
      assert full_disk["tools"] == []
      assert full_disk["stale"] == (grant == "unknown")

      expected_reason =
        case grant do
          "granted" -> "macos_grant_measured"
          "denied" -> "macos_grant_denied"
          "unknown" -> "macos_grant_probe_unavailable"
        end

      assert full_disk["reason"] == expected_reason

      refute items["accessibility"]["supported"]
      assert items["accessibility"]["configuredLevel"] == "off"
      assert items["accessibility"]["tools"] == []
      assert items["accessibility"]["reason"] == "peekaboo_not_installed"
    end
  end

  test "missing helper leaves grants unknown without prompting" do
    assert HostProbe.tcc_status() == {:error, :probe_unavailable}
    assert {:ok, snapshot} = Capabilities.get(platform: {:unix, :darwin}, capability_probe: HelperProbe)
    items = Map.new(snapshot["items"], &{&1["id"], &1})

    for id <- ~w(accessibility screen_recording event_synthesizing full_disk_access) do
      assert items[id]["osGrant"] == "unknown"
      assert items[id]["configuredLevel"] == "off"
      assert items[id]["stale"]
    end

    assert items["accessibility"]["reason"] == "macos_grant_probe_unavailable"
    assert items["full_disk_access"]["reason"] == "macos_has_no_nonprompting_full_disk_grant_query"
  end

  test "helper must be an absolute executable file", %{tmp_dir: dir} do
    script = Path.join(dir, "not executable")
    File.write!(script, "#!/bin/sh\nexit 0\n")
    File.chmod!(script, 0o600)

    for path <- ["", "relative/probe", script, dir, Path.join(dir, "missing")] do
      System.put_env("LEMON_TCC_PROBE", path)
      assert HostProbe.tcc_status() == {:error, :probe_unavailable}
    end
  end

  test "failed, malformed or incompatible status is unavailable", %{tmp_dir: dir} do
    for body <- [
          "exit 1",
          "printf '%s\\n' 'not json'",
          "printf '%s\\n' '[]'",
          "printf '%s\\n' '{\"version\":2,\"accessibility\":\"granted\"}'",
          "printf '%s\\n' '{\"accessibility\":\"granted\"}'"
        ] do
      write_probe(dir, body)
      assert HostProbe.tcc_status() == {:error, :probe_unavailable}
    end
  end

  defp write_probe(dir, body) do
    path = Path.join(dir, "TCC probe")

    File.write!(
      path,
      "#!/bin/sh\n[ \"$#\" -eq 2 ] && [ \"$1\" = --status ] && [ \"$2\" = --json ] || exit 64\n#{body}\n"
    )

    File.chmod!(path, 0o700)
    System.put_env("LEMON_TCC_PROBE", path)
  end
end
