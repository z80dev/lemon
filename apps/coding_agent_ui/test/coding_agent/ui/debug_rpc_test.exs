defmodule CodingAgent.UI.DebugRPCTest do
  use ExUnit.Case, async: true

  alias CodingAgent.UI.DebugRPC

  # ============================================================================
  # Test Helpers - Mock Output Device
  # ============================================================================

  defmodule MockOutput do
    @moduledoc """
    A mock output device that captures JSON output for testing.
    """

    use GenServer

    def start_link(opts \\ []) do
      GenServer.start_link(__MODULE__, opts)
    end

    def get_output(device) do
      GenServer.call(device, :get_output)
    end

    def get_last_json(device) do
      lines = get_output(device)

      case List.last(lines) do
        nil -> nil
        line -> Jason.decode!(line)
      end
    end

    def get_all_json(device) do
      get_output(device)
      |> Enum.map(&Jason.decode!/1)
    end

    def clear(device) do
      GenServer.call(device, :clear)
    end

    # GenServer callbacks

    @impl true
    def init(_opts) do
      {:ok, %{output: []}}
    end

    @impl true
    def handle_call(:get_output, _from, state) do
      {:reply, Enum.reverse(state.output), state}
    end

    @impl true
    def handle_call(:clear, _from, _state) do
      {:reply, :ok, %{output: []}}
    end

    # Handle IO protocol messages
    @impl true
    def handle_info({:io_request, from, reply_as, request}, state) do
      {result, new_state} = handle_io_request(request, state, from, reply_as)

      case result do
        :noreply -> :ok
        reply -> send(from, {:io_reply, reply_as, reply})
      end

      {:noreply, new_state}
    end

    defp handle_io_request({:put_chars, _encoding, chars}, state, from, reply_as) do
      line = IO.chardata_to_string(chars) |> String.trim_trailing("\n")
      send(from, {:io_reply, reply_as, :ok})
      {:noreply, %{state | output: [line | state.output]}}
    end

    defp handle_io_request({:put_chars, chars}, state, from, reply_as) do
      line = IO.chardata_to_string(chars) |> String.trim_trailing("\n")
      send(from, {:io_reply, reply_as, :ok})
      {:noreply, %{state | output: [line | state.output]}}
    end

    defp handle_io_request(:getopts, state, from, reply_as) do
      send(from, {:io_reply, reply_as, []})
      {:noreply, state}
    end

    defp handle_io_request({:setopts, _opts}, state, from, reply_as) do
      send(from, {:io_reply, reply_as, :ok})
      {:noreply, state}
    end

    defp handle_io_request(_request, state, from, reply_as) do
      send(from, {:io_reply, reply_as, {:error, :request}})
      {:noreply, state}
    end
  end

  defp wait_for_output(output, timeout_ms \\ 1000) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_wait_for_output(output, deadline)
  end

  defp do_wait_for_output(output, deadline) do
    output_lines = MockOutput.get_output(output)

    if output_lines != [] do
      output_lines
    else
      if System.monotonic_time(:millisecond) >= deadline do
        []
      else
        Process.sleep(10)
        do_wait_for_output(output, deadline)
      end
    end
  end

  # ============================================================================
  # Setup
  # ============================================================================

  setup do
    {:ok, output} = MockOutput.start_link()

    # Use a unique name for each test to allow async tests
    name = :"debug_rpc_test_#{:erlang.unique_integer([:positive])}"

    {:ok, rpc} =
      DebugRPC.start_link(
        name: name,
        output_device: output,
        timeout: 500
      )

    on_exit(fn ->
      if Process.alive?(rpc), do: GenServer.stop(rpc)
      if Process.alive?(output), do: GenServer.stop(output)
    end)

    %{rpc: rpc, output: output}
  end

  # ============================================================================
  # Request Message Format Tests
  # ============================================================================

  describe "ui_request message format" do
    test "select sends ui_request with correct format", %{rpc: rpc, output: output} do
      # Start async select (will timeout, but we just want to check the output)
      task =
        Task.async(fn ->
          DebugRPC.select("Choose one", [%{label: "A", value: "a", description: "Desc"}],
            server: rpc
          )
        end)

      # Wait for request to be sent
      Process.sleep(50)

      [request_json | _] = wait_for_output(output)
      request = Jason.decode!(request_json)

      assert request["type"] == "ui_request"
      assert is_binary(request["id"])
      assert request["method"] == "select"
      assert request["params"]["title"] == "Choose one"
      assert length(request["params"]["options"]) == 1
      assert hd(request["params"]["options"])["value"] == "a"

      # Cancel the task (it will timeout)
      Task.shutdown(task, :brutal_kill)
    end

    test "confirm sends ui_request with correct format", %{rpc: rpc, output: output} do
      task =
        Task.async(fn ->
          DebugRPC.confirm("Are you sure?", "This will delete everything", server: rpc)
        end)

      Process.sleep(50)

      [request_json | _] = wait_for_output(output)
      request = Jason.decode!(request_json)

      assert request["type"] == "ui_request"
      assert request["method"] == "confirm"
      assert request["params"]["title"] == "Are you sure?"
      assert request["params"]["message"] == "This will delete everything"

      Task.shutdown(task, :brutal_kill)
    end

    test "input sends ui_request with correct format", %{rpc: rpc, output: output} do
      task =
        Task.async(fn ->
          DebugRPC.input("Enter name", "Your name...", server: rpc)
        end)

      Process.sleep(50)

      [request_json | _] = wait_for_output(output)
      request = Jason.decode!(request_json)

      assert request["type"] == "ui_request"
      assert request["method"] == "input"
      assert request["params"]["title"] == "Enter name"
      assert request["params"]["placeholder"] == "Your name..."

      Task.shutdown(task, :brutal_kill)
    end

    test "editor sends ui_request with correct format", %{rpc: rpc, output: output} do
      task =
        Task.async(fn ->
          DebugRPC.editor("Edit message", "Initial text", server: rpc)
        end)

      Process.sleep(50)

      [request_json | _] = wait_for_output(output)
      request = Jason.decode!(request_json)

      assert request["type"] == "ui_request"
      assert request["method"] == "editor"
      assert request["params"]["title"] == "Edit message"
      assert request["params"]["prefill"] == "Initial text"

      Task.shutdown(task, :brutal_kill)
    end
  end

  # ============================================================================
  # Response Handling Tests
  # ============================================================================

  describe "handle_response/2" do
    test "select receives response via handle_response", %{rpc: rpc, output: output} do
      # Start async select
      task =
        Task.async(fn ->
          DebugRPC.select("Choose", [%{label: "A", value: "a", description: nil}], server: rpc)
        end)

      # Wait for request to be sent and get its ID
      Process.sleep(50)
      [request_json | _] = wait_for_output(output)
      request = Jason.decode!(request_json)
      request_id = request["id"]

      # Send response via handle_response
      DebugRPC.handle_response(rpc, %{"id" => request_id, "result" => "a", "error" => nil})

      # Task should complete with the result
      result = Task.await(task)
      assert result == {:ok, "a"}
    end

    test "confirm receives boolean response", %{rpc: rpc, output: output} do
      task = Task.async(fn -> DebugRPC.confirm("Sure?", "Really?", server: rpc) end)

      Process.sleep(50)
      [request_json | _] = wait_for_output(output)
      request = Jason.decode!(request_json)

      DebugRPC.handle_response(rpc, %{"id" => request["id"], "result" => true, "error" => nil})

      assert Task.await(task) == {:ok, true}
    end

    test "input receives string response", %{rpc: rpc, output: output} do
      task = Task.async(fn -> DebugRPC.input("Name?", nil, server: rpc) end)

      Process.sleep(50)
      [request_json | _] = wait_for_output(output)
      request = Jason.decode!(request_json)

      DebugRPC.handle_response(rpc, %{"id" => request["id"], "result" => "John", "error" => nil})

      assert Task.await(task) == {:ok, "John"}
    end

    test "handles nil result (cancellation)", %{rpc: rpc, output: output} do
      task =
        Task.async(fn ->
          DebugRPC.select("Choose", [%{label: "A", value: "a", description: nil}], server: rpc)
        end)

      Process.sleep(50)
      [request_json | _] = wait_for_output(output)
      request = Jason.decode!(request_json)

      DebugRPC.handle_response(rpc, %{"id" => request["id"], "result" => nil, "error" => nil})

      assert Task.await(task) == {:ok, nil}
    end

    test "handles error response", %{rpc: rpc, output: output} do
      task =
        Task.async(fn ->
          DebugRPC.select("Choose", [%{label: "A", value: "a", description: nil}], server: rpc)
        end)

      Process.sleep(50)
      [request_json | _] = wait_for_output(output)
      request = Jason.decode!(request_json)

      DebugRPC.handle_response(rpc, %{"id" => request["id"], "error" => "User cancelled"})

      assert Task.await(task) == {:error, "User cancelled"}
    end

    test "error takes precedence over result when both present", %{rpc: rpc, output: output} do
      # This tests the parse_response error-first behavior
      task =
        Task.async(fn ->
          DebugRPC.select("Choose", [%{label: "A", value: "a", description: nil}], server: rpc)
        end)

      Process.sleep(50)
      [request_json | _] = wait_for_output(output)
      request = Jason.decode!(request_json)

      # Buggy client sends both result and error - error should take precedence
      DebugRPC.handle_response(rpc, %{
        "id" => request["id"],
        "result" => "should be ignored",
        "error" => "actual error"
      })

      assert Task.await(task) == {:error, "actual error"}
    end
  end

  # ============================================================================
  # Timeout Tests
  # ============================================================================

  describe "timeout handling" do
    test "returns timeout error when no response received", %{rpc: rpc} do
      # Use short timeout via server config (already 500ms in setup)
      result =
        DebugRPC.select("Choose", [%{label: "A", value: "a", description: nil}], server: rpc)

      assert result == {:error, :timeout}
    end
  end

  # ============================================================================
  # Signal (Notification) Tests
  # ============================================================================

  describe "notify/2" do
    test "sends ui_notify signal via public API", %{rpc: rpc, output: output} do
      # Call via public API with server option
      DebugRPC.notify("Hello!", :info, server: rpc)

      Process.sleep(50)

      signal = MockOutput.get_last_json(output)

      assert signal["type"] == "ui_notify"
      assert signal["params"]["message"] == "Hello!"
      assert signal["params"]["notify_type"] == "info"
      refute Map.has_key?(signal, "id")
    end

    test "sends ui_notify signal with different notification types", %{rpc: rpc, output: output} do
      for type <- [:info, :warn, :error, :success] do
        MockOutput.clear(output)
        DebugRPC.notify("Test #{type}", type, server: rpc)

        Process.sleep(50)

        signal = MockOutput.get_last_json(output)
        assert signal["params"]["notify_type"] == Atom.to_string(type)
      end
    end
  end

  describe "set_status/2" do
    test "sends ui_status signal", %{rpc: rpc, output: output} do
      GenServer.cast(rpc, {:signal, "ui_status", %{key: "model", text: "claude-3"}})

      Process.sleep(50)

      signal = MockOutput.get_last_json(output)

      assert signal["type"] == "ui_status"
      assert signal["params"]["key"] == "model"
      assert signal["params"]["text"] == "claude-3"
    end
  end

  describe "set_widget/3" do
    test "sends ui_widget signal via public API", %{rpc: rpc, output: output} do
      DebugRPC.set_widget("files", ["a.txt", "b.txt"], server: rpc, position: :above)

      Process.sleep(50)

      signal = MockOutput.get_last_json(output)

      assert signal["type"] == "ui_widget"
      assert signal["params"]["key"] == "files"
      assert signal["params"]["content"] == ["a.txt", "b.txt"]
      # Opts should be normalized to a map (not a keyword list)
      assert is_map(signal["params"]["opts"])
      assert signal["params"]["opts"]["position"] == "above"
      # :server should be stripped from the wire opts
      refute Map.has_key?(signal["params"]["opts"], "server")
    end

    test "normalizes keyword list opts to map", %{rpc: rpc, output: output} do
      DebugRPC.set_widget("widget", "content", server: rpc, foo: :bar, baz: 123)

      Process.sleep(50)

      signal = MockOutput.get_last_json(output)

      assert signal["params"]["opts"] == %{"foo" => "bar", "baz" => 123}
    end
  end

  describe "set_working_message/1" do
    test "sends ui_working signal", %{rpc: rpc, output: output} do
      GenServer.cast(rpc, {:signal, "ui_working", %{message: "Processing..."}})

      Process.sleep(50)

      signal = MockOutput.get_last_json(output)

      assert signal["type"] == "ui_working"
      assert signal["params"]["message"] == "Processing..."
    end

    test "sends ui_working with nil to clear", %{rpc: rpc, output: output} do
      GenServer.cast(rpc, {:signal, "ui_working", %{message: nil}})

      Process.sleep(50)

      signal = MockOutput.get_last_json(output)

      assert signal["type"] == "ui_working"
      assert signal["params"]["message"] == nil
    end
  end

  describe "set_title/1" do
    test "sends ui_set_title signal", %{rpc: rpc, output: output} do
      GenServer.cast(rpc, {:signal, "ui_set_title", %{title: "Lemon Agent"}})

      Process.sleep(50)

      signal = MockOutput.get_last_json(output)

      assert signal["type"] == "ui_set_title"
      assert signal["params"]["title"] == "Lemon Agent"
    end
  end

  describe "set_editor_text/1 and get_editor_text/0" do
    test "sends signal and tracks text locally", %{rpc: rpc, output: output} do
      GenServer.cast(rpc, {:signal, "ui_set_editor_text", %{text: "Hello World"}})

      Process.sleep(50)

      # Verify signal was sent
      signal = MockOutput.get_last_json(output)
      assert signal["type"] == "ui_set_editor_text"
      assert signal["params"]["text"] == "Hello World"

      # Verify it's tracked locally
      text = GenServer.call(rpc, :get_editor_text)
      assert text == "Hello World"
    end
  end

  describe "has_ui?/0" do
    test "returns true" do
      assert DebugRPC.has_ui?() == true
    end
  end

  # ============================================================================
  # Edge Case Tests
  # ============================================================================

  describe "error handling" do
    test "ignores response without matching request id", %{rpc: rpc, output: output} do
      # Start a request
      task =
        Task.async(fn ->
          DebugRPC.select("Choose", [%{label: "A", value: "a", description: nil}], server: rpc)
        end)

      Process.sleep(50)
      [request_json | _] = wait_for_output(output)
      request = Jason.decode!(request_json)

      # Send response with wrong ID (should be ignored)
      DebugRPC.handle_response(rpc, %{"id" => "wrong-id", "result" => "ignored"})

      # Send correct response
      DebugRPC.handle_response(rpc, %{"id" => request["id"], "result" => "correct"})

      assert Task.await(task) == {:ok, "correct"}
    end

    test "handles response without id field", %{rpc: rpc, output: output} do
      task =
        Task.async(fn ->
          DebugRPC.select("Choose", [%{label: "A", value: "a", description: nil}], server: rpc)
        end)

      Process.sleep(50)
      [request_json | _] = wait_for_output(output)
      request = Jason.decode!(request_json)

      # Send response without id (should be ignored/logged)
      DebugRPC.handle_response(rpc, %{"result" => "no_id"})

      # Send correct response
      DebugRPC.handle_response(rpc, %{"id" => request["id"], "result" => "correct"})

      assert Task.await(task) == {:ok, "correct"}
    end
  end

  describe "concurrent requests" do
    test "handles multiple concurrent requests with different IDs", %{rpc: rpc, output: output} do
      # Start multiple requests concurrently
      task1 =
        Task.async(fn ->
          DebugRPC.select("First", [%{label: "A", value: "a", description: nil}], server: rpc)
        end)

      task2 =
        Task.async(fn ->
          DebugRPC.confirm("Second", "Sure?", server: rpc)
        end)

      # Wait for requests to be sent
      Process.sleep(100)

      # Get all requests
      requests = MockOutput.get_all_json(output)
      assert length(requests) == 2

      # Find each request and respond appropriately
      Enum.each(requests, fn request ->
        response =
          case request["method"] do
            "select" -> %{"id" => request["id"], "result" => "selected", "error" => nil}
            "confirm" -> %{"id" => request["id"], "result" => true, "error" => nil}
          end

        DebugRPC.handle_response(rpc, response)
      end)

      # Both should complete successfully
      result1 = Task.await(task1)
      result2 = Task.await(task2)

      assert result1 == {:ok, "selected"}
      assert result2 == {:ok, true}
    end
  end

  # ============================================================================
  # Server Shutdown Tests
  # ============================================================================

  describe "server shutdown" do
    test "fails pending requests on shutdown", %{output: output} do
      name = :"shutdown_test_#{:erlang.unique_integer([:positive])}"

      {:ok, rpc} =
        DebugRPC.start_link(
          name: name,
          output_device: output,
          timeout: 5000
        )

      # Start a request
      task =
        Task.async(fn ->
          DebugRPC.select("Choose", [%{label: "A", value: "a", description: nil}], server: rpc)
        end)

      # Wait for request to be sent
      Process.sleep(50)

      # Stop the server
      GenServer.stop(rpc)

      # Request should fail with server_shutdown
      result = Task.await(task)
      assert result == {:error, :server_shutdown}
    end
  end
end
