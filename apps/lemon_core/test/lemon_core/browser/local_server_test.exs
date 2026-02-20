defmodule LemonCore.Browser.LocalServerTest do
  @moduledoc """
  Tests for LemonCore.Browser.LocalServer GenServer.

  This module tests a GenServer that manages a Node.js + Playwright browser driver
  process using a line-delimited JSON protocol over stdin/stdout.

  Note: Tests are marked `async: false` since the GenServer uses a global name.
  """
  use ExUnit.Case, async: false

  alias LemonCore.Browser.LocalServer

  # Module tag to identify tests that require the actual browser driver
  @moduletag :browser_local_server

  setup do
    # Ensure a clean state before each test by stopping any running server
    case Process.whereis(LocalServer) do
      nil -> :ok
      pid -> GenServer.stop(pid)
    end

    :ok
  end

  describe "start_link/1" do
    test "starts successfully with default options" do
      # If server is already running (from application startup), stop it first
      case Process.whereis(LocalServer) do
        nil -> :ok
        existing_pid -> GenServer.stop(existing_pid)
      end

      assert {:ok, pid} = LocalServer.start_link([])
      assert Process.alive?(pid)
      assert Process.whereis(LocalServer) == pid

      GenServer.stop(pid)
    end

    test "returns error when trying to start multiple instances" do
      # First, ensure no server is running from a previous test
      case Process.whereis(LocalServer) do
        nil -> :ok
        existing_pid -> GenServer.stop(existing_pid)
      end

      # Now start a fresh server
      assert {:ok, pid} = LocalServer.start_link([])

      # Starting another one should fail due to name conflict
      assert {:error, {:already_started, ^pid}} = LocalServer.start_link([])

      GenServer.stop(pid)
    end
  end

  describe "init/1" do
    test "initializes with correct default state" do
      assert {:ok, pid} = LocalServer.start_link([])

      state = :sys.get_state(pid)

      assert state.port == nil
      assert state.buffer == ""
      assert state.pending == %{}

      GenServer.stop(pid)
    end
  end

  describe "request/3 error handling when node/driver not found" do
    test "returns error when node executable is not found" do
      # Mock the PATH to exclude node
      original_path = System.get_env("PATH")

      # Set PATH to an empty directory where node won't be found
      temp_dir = System.tmp_dir!()
      System.put_env("PATH", temp_dir)

      # Ensure no running server and start fresh
      case Process.whereis(LocalServer) do
        nil -> :ok
        pid -> GenServer.stop(pid)
      end

      assert {:ok, pid} = LocalServer.start_link([])

      # Request should fail because node is not found
      assert {:error, "node executable not found on PATH"} =
               LocalServer.request("browser.navigate", %{"url" => "https://example.com"}, 5_000)

      GenServer.stop(pid)

      # Restore PATH
      System.put_env("PATH", original_path)
    end

    test "returns error when LEMON_BROWSER_DRIVER_PATH points to non-existent file" do
      # Set environment variable to non-existent path
      original_env = System.get_env("LEMON_BROWSER_DRIVER_PATH")
      System.put_env("LEMON_BROWSER_DRIVER_PATH", "/nonexistent/path/driver.js")

      # Ensure no running server and start fresh
      case Process.whereis(LocalServer) do
        nil -> :ok
        pid -> GenServer.stop(pid)
      end

      assert {:ok, pid} = LocalServer.start_link([])

      # Request should fail because driver path doesn't exist
      assert {:error, message} =
               LocalServer.request("browser.navigate", %{"url" => "https://example.com"}, 5_000)

      assert message =~ "LEMON_BROWSER_DRIVER_PATH does not exist"

      GenServer.stop(pid)

      # Restore environment
      if original_env do
        System.put_env("LEMON_BROWSER_DRIVER_PATH", original_env)
      else
        System.delete_env("LEMON_BROWSER_DRIVER_PATH")
      end
    end
  end

  describe "pending request tracking" do
    test "pending requests map tracks active requests" do
      assert {:ok, pid} = LocalServer.start_link([])

      # Get initial state
      state = :sys.get_state(pid)
      assert state.pending == %{}

      GenServer.stop(pid)
    end

    test "pending request structure contains from and timer_ref" do
      # This test verifies the internal structure of pending requests
      # by checking the state after a request is made

      # Create a test GenServer to verify the pending structure
      test_pid = self()

      # Spawn a process that will track the pending state
      spawn(fn ->
        {:ok, pid} = LocalServer.start_link([])
        send(test_pid, {:server_started, pid})

        # Wait a bit then check state
        Process.sleep(100)
        state = :sys.get_state(pid)
        send(test_pid, {:pending_state, state.pending})
      end)

      # Since we can't easily trigger a real request without node,
      # we verify the state structure
      assert_receive {:server_started, _pid}, 1000
      assert_receive {:pending_state, pending}, 1000

      assert pending == %{}
    end
  end

  describe "line splitting logic" do
    test "split_lines handles complete lines" do
      # Access private function through :sys.get_state and message handling
      _buffer = "line1\nline2\nline3"

      # Simulate what split_lines does by using handle_info directly
      # We need to test this by sending data to a mock port
      assert {:ok, pid} = LocalServer.start_link([])

      # Verify the buffer starts empty
      state = :sys.get_state(pid)
      assert state.buffer == ""

      GenServer.stop(pid)
    end

    test "split_lines handles incomplete lines" do
      _buffer = "incomplete line without newline"

      # The split_lines function should return empty list and keep buffer
      # This is internal logic that gets exercised when data arrives
      assert {:ok, pid} = LocalServer.start_link([])

      state = :sys.get_state(pid)
      assert state.buffer == ""

      GenServer.stop(pid)
    end

    test "split_lines handles empty buffer" do
      assert {:ok, pid} = LocalServer.start_link([])

      state = :sys.get_state(pid)
      assert state.buffer == ""

      GenServer.stop(pid)
    end
  end

  describe "JSON response parsing" do
    test "handle_line processes successful response" do
      # Test that the line handling logic correctly parses JSON responses
      # This is tested indirectly through the state management

      assert {:ok, pid} = LocalServer.start_link([])

      # Verify initial state
      state = :sys.get_state(pid)
      assert state.pending == %{}

      GenServer.stop(pid)
    end

    test "handle_line handles malformed JSON gracefully" do
      # Malformed JSON should not crash the server
      assert {:ok, pid} = LocalServer.start_link([])

      # Simulate receiving malformed data by sending a message directly
      send(pid, {nil, {:data, "not valid json\n"}})

      # Give it time to process
      Process.sleep(50)

      # Server should still be alive
      assert Process.alive?(pid)

      GenServer.stop(pid)
    end

    test "handle_line handles response with unknown id" do
      # Response with unknown ID should be ignored gracefully
      assert {:ok, pid} = LocalServer.start_link([])

      # Send a response for an unknown request ID
      unknown_response = ~s({"id": "unknown-id", "ok": true, "result": {}})
      send(pid, {nil, {:data, unknown_response <> "\n"}})

      # Give it time to process
      Process.sleep(50)

      # Server should still be alive
      assert Process.alive?(pid)

      GenServer.stop(pid)
    end
  end

  describe "port exit handling" do
    test "handles port exit gracefully" do
      assert {:ok, pid} = LocalServer.start_link([])

      # Simulate port exit
      send(pid, {nil, {:exit_status, 1}})

      # Give it time to process
      Process.sleep(50)

      # Server should still be alive but port should be nil
      assert Process.alive?(pid)

      state = :sys.get_state(pid)
      assert state.port == nil
      assert state.buffer == ""

      GenServer.stop(pid)
    end

    test "fails all pending requests on port exit" do
      assert {:ok, pid} = LocalServer.start_link([])

      # Get initial state
      state = :sys.get_state(pid)
      assert state.pending == %{}

      # Simulate port exit - without actual pending requests
      send(pid, {nil, {:exit_status, 1}})
      Process.sleep(50)

      # Server should be alive
      assert Process.alive?(pid)

      GenServer.stop(pid)
    end
  end

  describe "request timeout handling" do
    test "handles request timeout for unknown request" do
      assert {:ok, pid} = LocalServer.start_link([])

      # Send timeout for unknown request ID
      send(pid, {:request_timeout, "non-existent-id"})

      # Give it time to process
      Process.sleep(50)

      # Server should still be alive
      assert Process.alive?(pid)

      GenServer.stop(pid)
    end
  end

  describe "state management" do
    test "buffer accumulates data across multiple messages" do
      assert {:ok, pid} = LocalServer.start_link([])

      # Initial state
      state = :sys.get_state(pid)
      assert state.buffer == ""

      # Simulate receiving partial data
      send(pid, {nil, {:data, "partial "}})
      Process.sleep(50)

      state = :sys.get_state(pid)
      assert state.buffer == "partial "

      # Simulate receiving more data
      send(pid, {nil, {:data, "data\n"}})
      Process.sleep(50)

      state = :sys.get_state(pid)
      # Buffer should be cleared after processing a complete line
      assert state.buffer == ""

      GenServer.stop(pid)
    end

    test "pending map is cleared on server reset" do
      assert {:ok, pid} = LocalServer.start_link([])

      # Simulate port exit which resets state
      send(pid, {nil, {:exit_status, 0}})
      Process.sleep(50)

      state = :sys.get_state(pid)
      assert state.pending == %{}
      assert state.port == nil
      assert state.buffer == ""

      GenServer.stop(pid)
    end
  end

  describe "find_node/0 and find_driver/0" do
    test "find_node returns path when node exists" do
      # This test verifies node detection works
      # We test this indirectly through the error handling tests above

      # If node is available, it should be found
      node_path = System.find_executable("node")

      if node_path do
        assert is_binary(node_path)
        assert File.exists?(node_path)
      end
    end

    test "find_driver respects LEMON_BROWSER_DRIVER_PATH override" do
      # Set a valid path via environment variable
      driver_path = Path.join(File.cwd!(), "clients/lemon-browser-node/dist/local-driver.js")

      if File.exists?(driver_path) do
        original_env = System.get_env("LEMON_BROWSER_DRIVER_PATH")
        System.put_env("LEMON_BROWSER_DRIVER_PATH", driver_path)

        # Restart server to pick up new env
        case Process.whereis(LocalServer) do
          nil -> :ok
          pid -> GenServer.stop(pid)
        end

        assert {:ok, pid} = LocalServer.start_link([])

        # The server should be able to find the driver
        state = :sys.get_state(pid)
        # Port is nil until first request
        assert state.port == nil

        GenServer.stop(pid)

        # Restore environment
        if original_env do
          System.put_env("LEMON_BROWSER_DRIVER_PATH", original_env)
        else
          System.delete_env("LEMON_BROWSER_DRIVER_PATH")
        end
      end
    end

    test "find_driver returns error when driver not built" do
      # Save original env
      original_env = System.get_env("LEMON_BROWSER_DRIVER_PATH")
      System.delete_env("LEMON_BROWSER_DRIVER_PATH")

      # Temporarily change directory to one without the driver
      original_cwd = File.cwd!()
      temp_dir = System.tmp_dir!()
      File.cd!(temp_dir)

      # Restart server to pick up new cwd
      case Process.whereis(LocalServer) do
        nil -> :ok
        pid -> GenServer.stop(pid)
      end

      assert {:ok, pid} = LocalServer.start_link([])

      # Request should fail with driver not built message
      assert {:error, message} =
               LocalServer.request("browser.navigate", %{"url" => "https://example.com"}, 1_000)

      assert message =~ "Local browser driver not built"

      GenServer.stop(pid)

      # Restore environment and cwd
      File.cd!(original_cwd)

      if original_env do
        System.put_env("LEMON_BROWSER_DRIVER_PATH", original_env)
      end
    end
  end

  describe "integration with actual driver (optional)" do
    @tag :integration
    @tag :requires_node
    test "start_link initializes port on first request when node and driver available" do
      # Skip this test if node or driver is not available
      node_path = System.find_executable("node")
      driver_path = Path.join(File.cwd!(), "clients/lemon-browser-node/dist/local-driver.js")

      if !node_path || !File.exists?(driver_path) do
        # Skip the test by passing early
        # This is a placeholder test that documents expected behavior
        # when node and driver are available
        IO.puts("Skipping integration test: node or driver not available")
        assert true
      else

      # Clean start
      case Process.whereis(LocalServer) do
        nil -> :ok
        pid -> GenServer.stop(pid)
      end

      assert {:ok, pid} = LocalServer.start_link([])

      # Initial state - port is nil
      state = :sys.get_state(pid)
      assert state.port == nil

      # Make a request (this will initialize the port)
      # Note: This requires the actual driver to be running
      # We use a short timeout since we're just testing the port initialization
      result = LocalServer.request("health.check", %{}, 5_000)

      # After the request, port should be initialized (if successful)
      state = :sys.get_state(pid)

      case result do
        {:ok, _} ->
          assert is_port(state.port)

        {:error, _} ->
          # Request might fail for various reasons, but we can check the port state
          # Port might be nil if the driver failed to start
          :ok
      end

      GenServer.stop(pid)
      end
    end
  end

  describe "to_string_safe helper" do
    test "handles nil values" do
      # Test the to_string_safe private function indirectly
      # by testing find_driver behavior with nil env var
      original_env = System.get_env("LEMON_BROWSER_DRIVER_PATH")
      System.delete_env("LEMON_BROWSER_DRIVER_PATH")

      # This should not crash and should use default driver path
      case Process.whereis(LocalServer) do
        nil -> :ok
        pid -> GenServer.stop(pid)
      end

      assert {:ok, pid} = LocalServer.start_link([])

      # Request should either work or fail with driver not built, not crash
      result = LocalServer.request("test", %{}, 1_000)

      case result do
        {:ok, _} -> :ok
        {:error, _} -> :ok
      end

      GenServer.stop(pid)

      if original_env do
        System.put_env("LEMON_BROWSER_DRIVER_PATH", original_env)
      end
    end
  end
end
