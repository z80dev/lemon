defmodule CodingAgent.ExecutionNode.HostInfoTest do
  use ExUnit.Case, async: true
  alias CodingAgent.ExecutionNode.HostInfo

  test "supported host snapshots contain measured non-null resources" do
    case :os.type() do
      {:unix, os} when os in [:darwin, :linux] ->
        assert {:ok, snapshot} = HostInfo.get(default_cwd: System.tmp_dir!())
        for key <- ~w(cpuCount memTotalBytes diskTotalBytes) do
          assert is_integer(snapshot[key]) and snapshot[key] > 0
        end
        for key <- ~w(memFreeBytes diskFreeBytes uptimeSec) do
          assert is_integer(snapshot[key]) and snapshot[key] >= 0
        end
        for key <- ~w(hostname os osVersion arch lemonVersion defaultCwd user) do
          assert is_binary(snapshot[key]) and snapshot[key] != ""
        end
        assert snapshot["lemonVersion"] == LemonCore.Update.Version.current()
      _ ->
        assert {:error, :host_metrics_unavailable} = HostInfo.get([])
    end
  end

  test "unsupported platforms fail explicitly instead of returning invented metrics" do
    assert {:error, :host_metrics_unavailable} = HostInfo.get(platform: {:unix, :unsupported}, default_cwd: System.tmp_dir!())
  end
end
