defmodule CodingAgent.ExecutionNode.CapabilitiesTest do
  use ExUnit.Case, async: true
  alias CodingAgent.ExecutionNode.Capabilities

  defmodule Probe do
    def executable(_), do: "/installed"
    def shell_available?, do: true
    def root_access(_), do: {:ok, true, true}
    def browser_status, do: {:ok, %{available: true, running: true}}
    def mcp_available?, do: true
    def tool_names(_, _), do: {:ok, ~w(read write bash browser_tabs browser_click)}
    def command("peekaboo", ["permissions", "status", "--json"]), do: {:ok, ~s({"data":{"permissions":[{"name":"Accessibility","isRequired":true,"isGranted":false},{"name":"Screen Recording","isRequired":true,"isGranted":true},{"name":"Event Synthesizing","isRequired":false,"isGranted":false}]}})}
    def command("xdotool", ["getdisplaygeometry"]), do: {:ok, "1920 1080"}
  end
  defmodule UnknownProbe do
    defdelegate executable(name), to: Probe
    defdelegate shell_available?(), to: Probe
    defdelegate root_access(opts), to: Probe
    defdelegate browser_status(), to: Probe
    defdelegate mcp_available?(), to: Probe
    defdelegate tool_names(cwd, opts), to: Probe
    def command(_, _), do: {:error, :inspection_unavailable}
  end
  defmodule AbsentProbe do
    def executable("peekaboo"), do: nil
    def executable("xdotool"), do: nil
    defdelegate executable(name), to: Probe
    defdelegate shell_available?(), to: Probe
    defdelegate root_access(opts), to: Probe
    def browser_status, do: {:error, :not_installed}
    defdelegate mcp_available?(), to: Probe
    defdelegate tool_names(cwd, opts), to: Probe
    def command(_, _), do: raise("Absent capabilities must not launch inspection programs")
  end
  defmodule ContradictoryProbe do
    defdelegate executable(name), to: Probe
    defdelegate shell_available?(), to: Probe
    defdelegate root_access(opts), to: Probe
    defdelegate browser_status(), to: Probe
    defdelegate mcp_available?(), to: Probe
    defdelegate tool_names(cwd, opts), to: Probe
    def command(_, _), do: {:ok, ~s({"permissions":[{"name":"Accessibility","granted":true},{"name":"Accessibility","granted":false}]})}
  end

  test "measured denial, grant, and unqueryable permissions remain distinct" do
    assert {:ok, snapshot} = Capabilities.get(platform: {:unix, :darwin}, capability_probe: Probe)
    by_id = Map.new(snapshot["items"], &{&1["id"], &1})
    assert by_id["accessibility"]["osGrant"] == "denied"
    assert by_id["accessibility"]["configuredLevel"] == "off"
    assert by_id["screen_recording"]["osGrant"] == "granted"
    assert by_id["screen_recording"]["configuredLevel"] == "read_only"
    assert by_id["event_synthesizing"]["osGrant"] == "denied"
    assert by_id["full_disk_access"]["osGrant"] == "unknown"
    assert by_id["connectors"]["tools"] == []
    assert by_id["connectors"]["osGrant"] == "unknown"
    for item <- snapshot["items"] do
      assert item["measuredAtMs"] == snapshot["measuredAtMs"]
      assert Enum.sort(Map.keys(item)) == Enum.sort(~w(id name category supported configuredLevel osGrant tools reason measuredAtMs stale))
    end
    assert by_id["accessibility"]["tools"] == ["bash"]
    refute inspect(snapshot) =~ "token"
  end

  test "unavailable or contradictory inspection never pretends denied or granted" do
    for probe <- [UnknownProbe, ContradictoryProbe] do
      assert {:ok, snapshot} = Capabilities.get(platform: {:unix, :darwin}, capability_probe: probe)
      item = Enum.find(snapshot["items"], &(&1["id"] == "accessibility"))
      assert item["osGrant"] == "unknown"
      assert item["configuredLevel"] == "off"
      assert item["stale"]
    end
  end

  test "absent tooling is unsupported, not a denied OS grant" do
    assert {:ok, snapshot} = Capabilities.get(platform: {:unix, :darwin}, capability_probe: AbsentProbe)
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
    assert {:ok, snapshot} = Capabilities.get(platform: {:unix, :linux}, capability_probe: UnknownProbe)
    item = Enum.find(snapshot["items"], &(&1["id"] == "x11_desktop"))
    assert item["osGrant"] == "unknown"
    assert item["configuredLevel"] == "off"
  end
end
