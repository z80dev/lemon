defmodule LemonCore.Browser.LocalServerTest do
  @moduledoc """
  Tests for LemonCore.Browser.LocalServer.

  These tests run LocalServer instances under isolated names so they do not
  interfere with the application-supervised global LocalServer process.
  """
  use ExUnit.Case, async: false

  alias LemonCore.Browser.LocalServer

  @moduletag :browser_local_server

  setup do
    name = {:global, {:local_server_test, self(), System.unique_integer([:positive])}}
    {:ok, pid} = LocalServer.start_link(name: name)

    on_exit(fn ->
      if Process.alive?(pid) do
        GenServer.stop(pid, :normal, 1_000)
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
      with_env("LEMON_BROWSER_DRIVER_PATH", "/nonexistent/path/driver.js", fn ->
        assert {:error, message} =
                 LocalServer.request(
                   server,
                   "browser.navigate",
                   %{"url" => "https://example.com"},
                   1_000
                 )

        assert message =~ "LEMON_BROWSER_DRIVER_PATH does not exist"
      end)
    end

    test "returns not built error when cwd has no driver", %{server: server} do
      with_env("LEMON_BROWSER_DRIVER_PATH", nil, fn ->
        with_cwd(System.tmp_dir!(), fn ->
          assert {:error, message} =
                   LocalServer.request(
                     server,
                     "browser.navigate",
                     %{"url" => "https://example.com"},
                     1_000
                   )

          assert message =~ "Local browser driver not built"
        end)
      end)
    end
  end

  describe "line handling" do
    test "keeps incomplete data in buffer", %{pid: pid} do
      send(pid, {nil, {:data, "partial "}})
      Process.sleep(20)
      assert :sys.get_state(pid).buffer == "partial "
    end

    test "clears buffer after receiving complete line", %{pid: pid} do
      send(pid, {nil, {:data, "partial "}})
      Process.sleep(20)
      send(pid, {nil, {:data, "line\n"}})
      Process.sleep(20)
      assert :sys.get_state(pid).buffer == ""
    end

    test "ignores malformed JSON lines without crashing", %{pid: pid} do
      send(pid, {nil, {:data, "not valid json\n"}})
      Process.sleep(20)
      assert Process.alive?(pid)
      assert :sys.get_state(pid).pending == %{}
    end

    test "ignores responses for unknown ids", %{pid: pid} do
      unknown_response = ~s({"id":"unknown-id","ok":true,"result":{}})
      send(pid, {nil, {:data, unknown_response <> "\n"}})
      Process.sleep(20)
      assert Process.alive?(pid)
      assert :sys.get_state(pid).pending == %{}
    end
  end

  describe "state resets" do
    test "resets port and buffer on port exit", %{pid: pid} do
      send(pid, {nil, {:data, "partial "}})
      Process.sleep(20)
      send(pid, {nil, {:exit_status, 1}})
      Process.sleep(20)

      state = :sys.get_state(pid)
      assert state.port == nil
      assert state.buffer == ""
      assert state.pending == %{}
      assert Process.alive?(pid)
    end

    test "ignores timeout message for unknown request id", %{pid: pid} do
      send(pid, {:request_timeout, "missing-id"})
      Process.sleep(20)
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

  defp with_cwd(path, fun) when is_binary(path) and is_function(fun, 0) do
    original = File.cwd!()
    File.cd!(path)

    try do
      fun.()
    after
      File.cd!(original)
    end
  end
end
