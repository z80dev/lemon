defmodule LemonBrowser.LocalServerTest do
  @moduledoc """
  Tests for LemonBrowser.LocalServer.

  These tests run LocalServer instances under isolated names so they do not
  interfere with the application-supervised global LocalServer process.
  """
  use ExUnit.Case, async: false

  alias LemonBrowser.LocalServer

  @moduletag :browser_local_server

  setup do
    name = {:global, {:local_server_test, self(), System.unique_integer([:positive])}}
    {:ok, pid} = LocalServer.start_link(name: name)

    on_exit(fn ->
      if Process.alive?(pid) do
        LocalServer.stop(name)
      end
    end)

    {:ok, server: name, pid: pid}
  end

  describe "start_link/1" do
    test "starts successfully with a custom name", %{server: server, pid: pid} do
      assert Process.alive?(pid)
      assert GenServer.whereis(server) == pid
    end

    test "returns already_started for duplicate name", %{server: server, pid: pid} do
      assert {:error, {:already_started, ^pid}} = LocalServer.start_link(name: server)
    end
  end

  describe "initial state" do
    test "starts with empty buffer and pending map", %{pid: pid} do
      state = :sys.get_state(pid)
      assert state.port == nil
      assert state.buffer == ""
      assert state.pending == %{}
    end

    test "reports local server status", %{server: server} do
      status = LocalServer.status(server)

      assert status.available == true
      assert status.running == false
      assert status.pending_requests == 0
      assert status.request_count == 0
      assert status.completed_count == 0
      assert status.failed_count == 0
      assert status.last_error == nil
      assert status.driver_config.mode == "local_cdp"
      assert status.driver_config.launches_browser == true
      assert status.driver_config.attach_only == false
      assert status.driver_config.cdp_endpoint_configured == false
    end

    test "reports remote CDP driver shape without exposing the endpoint", %{server: server} do
      endpoint = "wss://user:secret@example.browser.test/devtools/browser/session"

      with_env("LEMON_BROWSER_CDP_ENDPOINT", endpoint, fn ->
        status = LocalServer.status(server)

        assert status.driver_config.mode == "remote_cdp"
        assert status.driver_config.launches_browser == false
        assert status.driver_config.attach_only == true
        assert status.driver_config.cdp_endpoint_configured == true
        assert is_binary(status.driver_config.cdp_endpoint_hash)
        refute inspect(status.driver_config) =~ endpoint
        refute inspect(status.driver_config) =~ "secret"
      end)
    end
  end

  describe "request errors" do
    test "returns node missing error when PATH has no node", %{server: server} do
      dir =
        Path.join(System.tmp_dir!(), "local_server_no_node_#{System.unique_integer([:positive])}")

      File.mkdir_p!(dir)

      with_env("PATH", dir, fn ->
        assert {:error, "node executable not found on PATH"} =
                 LocalServer.request(
                   server,
                   "browser.navigate",
                   %{"url" => "https://example.com"},
                   1_000
                 )
      end)
    end

    test "returns configured driver missing error", %{server: server} do
      with_driver_env("/nonexistent/path/driver.js", fn ->
        assert {:error, message} =
                 LocalServer.request(
                   server,
                   "browser.navigate",
                   %{"url" => "https://example.com"},
                   1_000
                 )

        assert message =~ "LEMON_BROWSER_DRIVER_PATH does not exist"
        status = LocalServer.status(server)
        assert status.failed_count == 0
        assert status.last_error =~ "LEMON_BROWSER_DRIVER_PATH does not exist"
      end)
    end

    @tag :tmp_dir
    test "returns not found error when no bundled or source driver exists", %{
      server: server,
      tmp_dir: root
    } do
      with_driver_env(nil, fn ->
        with_env("LEMON_PATH", root, fn ->
          assert {:error, message} =
                   LocalServer.request(
                     server,
                     "browser.navigate",
                     %{"url" => "https://example.com"},
                     1_000
                   )

          assert message =~ "Local browser driver not found"
        end)
      end)
    end

    @tag :tmp_dir
    test "resolves a source checkout's driver from LEMON_PATH, not the cwd", %{tmp_dir: root} do
      driver = Path.join(root, "clients/lemon-browser-node/dist/local-driver.js")
      File.mkdir_p!(Path.dirname(driver))
      File.write!(driver, "process.exit(0);")

      with_driver_env(nil, fn ->
        with_env("LEMON_PATH", root, fn ->
          assert {:ok, %{"driverPath" => ^driver}} = LocalServer.configuration()
        end)
      end)
    end
  end

  describe "line handling" do
    test "keeps incomplete data in buffer", %{pid: pid} do
      send(pid, {nil, {:data, "partial "}})
      assert :sys.get_state(pid).buffer == "partial "
    end

    test "clears buffer after receiving complete line", %{pid: pid} do
      send(pid, {nil, {:data, "partial "}})
      :sys.get_state(pid)
      send(pid, {nil, {:data, "line\n"}})
      assert :sys.get_state(pid).buffer == ""
    end

    test "ignores malformed JSON lines without crashing", %{pid: pid} do
      send(pid, {nil, {:data, "not valid json\n"}})
      :sys.get_state(pid)
      assert Process.alive?(pid)
      assert :sys.get_state(pid).pending == %{}
    end

    test "ignores responses for unknown ids", %{pid: pid} do
      unknown_response = ~s({"id":"unknown-id","ok":true,"result":{}})
      send(pid, {nil, {:data, unknown_response <> "\n"}})
      :sys.get_state(pid)
      assert Process.alive?(pid)
      assert :sys.get_state(pid).pending == %{}
    end
  end

  describe "state resets" do
    test "resets port and buffer on port exit", %{pid: pid} do
      send(pid, {nil, {:data, "partial "}})
      :sys.get_state(pid)
      send(pid, {nil, {:exit_status, 1}})

      state = :sys.get_state(pid)
      assert state.port == nil
      assert state.buffer == ""
      assert state.pending == %{}
      assert Process.alive?(pid)
    end

    test "ignores timeout message for unknown request id", %{pid: pid} do
      send(pid, {:request_timeout, "missing-id"})
      :sys.get_state(pid)
      assert Process.alive?(pid)
      assert :sys.get_state(pid).pending == %{}
    end
  end

  defp with_env(var, value, fun) when is_function(fun, 0) do
    original = System.get_env(var)

    if is_nil(value) do
      System.delete_env(var)
    else
      System.put_env(var, value)
    end

    try do
      fun.()
    after
      if is_nil(original) do
        System.delete_env(var)
      else
        System.put_env(var, original)
      end
    end
  end

  # The driver is resolved after `node` is found on PATH, so these tests need a
  # `node` that exists regardless of what the host has installed. It is never
  # spawned: every case here fails before the port is opened.
  defp with_driver_env(driver_path, fun) when is_function(fun, 0) do
    dir =
      Path.join(System.tmp_dir!(), "local_server_fake_node_#{System.unique_integer([:positive])}")

    File.mkdir_p!(dir)
    node = Path.join(dir, "node")
    File.write!(node, "#!/bin/sh\nexit 0\n")
    File.chmod!(node, 0o755)

    try do
      with_env("PATH", dir <> ":" <> System.get_env("PATH", ""), fn ->
        with_env("LEMON_BROWSER_DRIVER_PATH", driver_path, fun)
      end)
    after
      File.rm_rf!(dir)
    end
  end
end
