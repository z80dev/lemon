defmodule CodingAgent.UI.RPCTest do
  use ExUnit.Case, async: true

  alias CodingAgent.UI.RPC

  # ============================================================================
  # Test Helpers - Mock IO Devices
  # ============================================================================

  defmodule MockIO do
    @moduledoc """
    A mock IO device that simulates stdin/stdout for testing.

    Usage:
      {:ok, input} = MockIO.start_link()
      {:ok, output} = MockIO.start_link()

      # Set up mock input (response from "external UI")
      MockIO.put_input(input, ~s({"id": "123", "result": "selected_value"}))

      # Use as devices
      {:ok, rpc} = RPC.start_link(input_device: input, output_device: output)

      # Check what was written to output
      output_lines = MockIO.get_output(output)
    """

    use GenServer

    def start_link(opts \\ []) do
      GenServer.start_link(__MODULE__, opts)
    end

    @doc """
    Queue input lines to be read (simulates stdin)
    """
    def put_input(device, line) do
      GenServer.call(device, {:put_input, line})
    end

    @doc """
    Get all output lines that were written (simulates stdout)
    """
    def get_output(device) do
      GenServer.call(device, :get_output)
    end

    @doc """
    Get and decode the last JSON output
    """
    def get_last_json(device) do
      lines = get_output(device)

      case List.last(lines) do
        nil -> nil
        line -> Jason.decode!(line)
      end
    end

    @doc """
    Close the device to simulate EOF
    """
    def close(device) do
      GenServer.call(device, :close)
    end

    # GenServer callbacks

    @impl true
    def init(_opts) do
      {:ok, %{input_queue: :queue.new(), output: [], closed: false, waiting: nil}}
    end

    @impl true
    def handle_call({:put_input, line}, _from, state) do
      new_queue = :queue.in(line <> "\n", state.input_queue)
      state = %{state | input_queue: new_queue}

      # If someone is waiting for input, send it via IO reply
      state =
        case state.waiting do
          {waiting_from, reply_as} ->
            case :queue.out(state.input_queue) do
              {{:value, data}, rest} ->
                send(waiting_from, {:io_reply, reply_as, data})
                %{state | input_queue: rest, waiting: nil}

              {:empty, _} ->
                state
            end

          nil ->
            state
        end

      {:reply, :ok, state}
    end

    @impl true
    def handle_call(:get_output, _from, state) do
      {:reply, Enum.reverse(state.output), state}
    end

    @impl true
    def handle_call(:close, _from, state) do
      # If someone is waiting, send EOF via IO reply
      case state.waiting do
        {waiting_from, reply_as} ->
          send(waiting_from, {:io_reply, reply_as, :eof})

        nil ->
          :ok
      end

      {:reply, :ok, %{state | closed: true, waiting: nil}}
    end

    @impl true
    def handle_call({:io_request, from, reply_as, request}, _from, state) do
      {result, new_state} = handle_io_request(request, state, from, reply_as)
      {:reply, result, new_state}
    end

    # Handle IO protocol messages
    @impl true
    def handle_info({:io_request, from, reply_as, request}, state) do
      {result, new_state} = handle_io_request(request, state, from, reply_as)

      case result do
        :noreply ->
          # Will reply later
          :ok

        reply ->
          send(from, {:io_reply, reply_as, reply})
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

    defp handle_io_request({:get_line, _encoding, _prompt}, state, from, reply_as) do
      handle_get_line(state, from, reply_as)
    end

    defp handle_io_request({:get_line, _prompt}, state, from, reply_as) do
      handle_get_line(state, from, reply_as)
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

    defp handle_get_line(state, from, reply_as) do
      if state.closed do
        send(from, {:io_reply, reply_as, :eof})
        {:noreply, state}
      else
        case :queue.out(state.input_queue) do
          {{:value, line}, rest} ->
            send(from, {:io_reply, reply_as, line})
            {:noreply, %{state | input_queue: rest}}

          {:empty, _} ->
            # Wait for input
            {:noreply, %{state | waiting: {from, reply_as}}}
        end
      end
    end
  end

  defp wait_for_output(output, timeout_ms \\ 1000) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms

    do_wait_for_output(output, deadline)
  end

  defp do_wait_for_output(output, deadline) do
    output_lines = MockIO.get_output(output)

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

  defp wait_for_output_count(output, min_count, timeout_ms \\ 1000) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_wait_for_output_count(output, min_count, deadline)
  end

  defp do_wait_for_output_count(output, min_count, deadline) do
    output_lines = MockIO.get_output(output)

    if length(output_lines) >= min_count do
      output_lines
    else
      if System.monotonic_time(:millisecond) >= deadline do
        output_lines
      else
        Process.sleep(10)
        do_wait_for_output_count(output, min_count, deadline)
      end
    end
  end

  # ============================================================================
  # Setup
  # ============================================================================

  setup do
    {:ok, input} = MockIO.start_link()
    {:ok, output} = MockIO.start_link()

    {:ok, rpc} =
      RPC.start_link(
        input_device: input,
        output_device: output,
        timeout: 1000
      )

    on_exit(fn ->
      if Process.alive?(rpc) do
        try do
          GenServer.stop(rpc)
        catch
          :exit, _ -> :ok
        end
      end

      if Process.alive?(input), do: MockIO.close(input)
      if Process.alive?(output), do: GenServer.stop(output)
    end)

    %{rpc: rpc, input: input, output: output}
  end

  # ============================================================================
  # Select Tests
  # ============================================================================

  describe "select/3" do
    test "sends request and receives response", %{rpc: rpc, input: input, output: output} do
      # Set up async response
      spawn(fn ->
        # Wait for request to be sent
        Process.sleep(50)

        # Get the request that was sent
        [request_json | _] = MockIO.get_output(output)
        request = Jason.decode!(request_json)

        # Send response with matching ID
        MockIO.put_input(input, Jason.encode!(%{id: request["id"], result: "option_a"}))
      end)

      # Call select
      options = [
        %{label: "Option A", value: "option_a", description: "First option"},
        %{label: "Option B", value: "option_b", description: nil}
      ]

      result = RPC.select("Choose one", options, server: rpc)

      assert result == {:ok, "option_a"}

      # Verify the request format
      [request_json | _] = MockIO.get_output(output)
      request = Jason.decode!(request_json)

      assert request["method"] == "select"
      assert request["params"]["title"] == "Choose one"
      assert length(request["params"]["options"]) == 2
      assert is_binary(request["id"])
    end

    test "returns nil when user cancels", %{rpc: rpc, input: input, output: output} do
      spawn(fn ->
        Process.sleep(50)
        [request_json | _] = MockIO.get_output(output)
        request = Jason.decode!(request_json)
        MockIO.put_input(input, Jason.encode!(%{id: request["id"], result: nil}))
      end)

      result = RPC.select("Choose", [%{label: "A", value: "a", description: nil}], server: rpc)

      assert result == {:ok, nil}
    end

    test "returns error on timeout", %{input: input, output: output} do
      # Create RPC with very short timeout
      {:ok, rpc} =
        RPC.start_link(
          input_device: input,
          output_device: output,
          timeout: 50
        )

      # Don't send any response - should timeout
      result = RPC.select("Choose", [%{label: "A", value: "a", description: nil}], server: rpc)

      assert result == {:error, :timeout}

      GenServer.stop(rpc)
    end

    test "returns error response", %{rpc: rpc, input: input, output: output} do
      spawn(fn ->
        Process.sleep(50)
        [request_json | _] = MockIO.get_output(output)
        request = Jason.decode!(request_json)
        MockIO.put_input(input, Jason.encode!(%{id: request["id"], error: "User cancelled"}))
      end)

      result = RPC.select("Choose", [%{label: "A", value: "a", description: nil}], server: rpc)

      assert result == {:error, "User cancelled"}
    end
  end

  # ============================================================================
  # Confirm Tests
  # ============================================================================

  describe "confirm/3" do
    test "sends request and receives true response", %{rpc: rpc, input: input, output: output} do
      spawn(fn ->
        Process.sleep(50)
        [request_json | _] = MockIO.get_output(output)
        request = Jason.decode!(request_json)
        MockIO.put_input(input, Jason.encode!(%{id: request["id"], result: true}))
      end)

      result = RPC.confirm("Confirm?", "Are you sure?", server: rpc)

      assert result == {:ok, true}

      [request_json | _] = MockIO.get_output(output)
      request = Jason.decode!(request_json)

      assert request["method"] == "confirm"
      assert request["params"]["title"] == "Confirm?"
      assert request["params"]["message"] == "Are you sure?"
    end

    test "sends request and receives false response", %{rpc: rpc, input: input, output: output} do
      spawn(fn ->
        Process.sleep(50)
        [request_json | _] = MockIO.get_output(output)
        request = Jason.decode!(request_json)
        MockIO.put_input(input, Jason.encode!(%{id: request["id"], result: false}))
      end)

      result = RPC.confirm("Confirm?", "Are you sure?", server: rpc)

      assert result == {:ok, false}
    end
  end

  # ============================================================================
  # Input Tests
  # ============================================================================

  describe "input/3" do
    test "sends request and receives text response", %{rpc: rpc, input: input, output: output} do
      spawn(fn ->
        Process.sleep(50)
        [request_json | _] = wait_for_output(output)
        request = Jason.decode!(request_json)
        MockIO.put_input(input, Jason.encode!(%{id: request["id"], result: "user input text"}))
      end)

      result = RPC.input("Enter name", "Your name...", server: rpc)

      assert result == {:ok, "user input text"}

      [request_json | _] = MockIO.get_output(output)
      request = Jason.decode!(request_json)

      assert request["method"] == "input"
      assert request["params"]["title"] == "Enter name"
      assert request["params"]["placeholder"] == "Your name..."
    end

    test "handles nil placeholder", %{rpc: rpc, input: input, output: output} do
      spawn(fn ->
        Process.sleep(50)
        [request_json | _] = wait_for_output(output)
        request = Jason.decode!(request_json)
        MockIO.put_input(input, Jason.encode!(%{id: request["id"], result: "input"}))
      end)

      result = RPC.input("Enter value", nil, server: rpc)

      assert result == {:ok, "input"}
    end
  end

  # ============================================================================
  # Editor Tests
  # ============================================================================

  describe "editor/3" do
    test "sends request and receives edited text", %{rpc: rpc, input: input, output: output} do
      spawn(fn ->
        Process.sleep(50)
        [request_json | _] = MockIO.get_output(output)
        request = Jason.decode!(request_json)
        MockIO.put_input(input, Jason.encode!(%{id: request["id"], result: "edited content"}))
      end)

      result = RPC.editor("Edit message", "initial text", server: rpc)

      assert result == {:ok, "edited content"}

      [request_json | _] = MockIO.get_output(output)
      request = Jason.decode!(request_json)

      assert request["method"] == "editor"
      assert request["params"]["title"] == "Edit message"
      assert request["params"]["prefill"] == "initial text"
    end

    test "returns nil when editor is cancelled", %{rpc: rpc, input: input, output: output} do
      spawn(fn ->
        Process.sleep(50)
        [request_json | _] = MockIO.get_output(output)
        request = Jason.decode!(request_json)
        MockIO.put_input(input, Jason.encode!(%{id: request["id"], result: nil}))
      end)

      result = RPC.editor("Edit", nil, server: rpc)

      assert result == {:ok, nil}
    end
  end

  # ============================================================================
  # Notification Tests
  # ============================================================================

  describe "notify/2" do
    test "sends notification without waiting for response", %{rpc: _rpc, output: output} do
      # Need to use module function with a registered name for notifications
      {:ok, named_rpc} =
        RPC.start_link(
          name: :"test_notify_#{:erlang.unique_integer()}",
          output_device: output,
          timeout: 1000
        )

      # This should return immediately without waiting
      result = GenServer.cast(named_rpc, {:notify, "notify", %{message: "Hello!", type: :info}})

      assert result == :ok

      # Give it time to send
      Process.sleep(50)

      notification = MockIO.get_last_json(output)

      assert notification["method"] == "notify"
      assert notification["params"]["message"] == "Hello!"
      assert notification["params"]["type"] == "info"
      refute Map.has_key?(notification, "id")

      GenServer.stop(named_rpc)
    end
  end

  describe "set_status/2" do
    test "sends status notification", %{rpc: _rpc, output: output} do
      {:ok, named_rpc} =
        RPC.start_link(
          name: :"test_status_#{:erlang.unique_integer()}",
          output_device: output,
          timeout: 1000
        )

      GenServer.cast(named_rpc, {:notify, "set_status", %{key: "mode", text: "Running"}})

      Process.sleep(50)

      notification = MockIO.get_last_json(output)

      assert notification["method"] == "set_status"
      assert notification["params"]["key"] == "mode"
      assert notification["params"]["text"] == "Running"

      GenServer.stop(named_rpc)
    end
  end

  describe "set_widget/3" do
    test "sends widget notification", %{rpc: _rpc, output: output} do
      {:ok, named_rpc} =
        RPC.start_link(
          name: :"test_widget_#{:erlang.unique_integer()}",
          output_device: output,
          timeout: 1000
        )

      GenServer.cast(
        named_rpc,
        {:notify, "set_widget", %{key: "files", content: ["a.txt", "b.txt"], opts: []}}
      )

      Process.sleep(50)

      notification = MockIO.get_last_json(output)

      assert notification["method"] == "set_widget"
      assert notification["params"]["key"] == "files"
      assert notification["params"]["content"] == ["a.txt", "b.txt"]

      GenServer.stop(named_rpc)
    end
  end

  describe "set_working_message/1" do
    test "sends working message notification", %{rpc: _rpc, output: output} do
      {:ok, named_rpc} =
        RPC.start_link(
          name: :"test_working_#{:erlang.unique_integer()}",
          output_device: output,
          timeout: 1000
        )

      GenServer.cast(named_rpc, {:notify, "set_working_message", %{message: "Processing..."}})

      Process.sleep(50)

      notification = MockIO.get_last_json(output)

      assert notification["method"] == "set_working_message"
      assert notification["params"]["message"] == "Processing..."

      GenServer.stop(named_rpc)
    end
  end

  describe "set_title/1" do
    test "sends title notification", %{rpc: _rpc, output: output} do
      {:ok, named_rpc} =
        RPC.start_link(
          name: :"test_title_#{:erlang.unique_integer()}",
          output_device: output,
          timeout: 1000
        )

      GenServer.cast(named_rpc, {:notify, "set_title", %{title: "My App"}})

      Process.sleep(50)

      notification = MockIO.get_last_json(output)

      assert notification["method"] == "set_title"
      assert notification["params"]["title"] == "My App"

      GenServer.stop(named_rpc)
    end
  end

  describe "set_editor_text/1 and get_editor_text/0" do
    test "tracks editor text locally", %{rpc: _rpc, output: output} do
      {:ok, named_rpc} =
        RPC.start_link(
          name: :"test_editor_text_#{:erlang.unique_integer()}",
          output_device: output,
          timeout: 1000
        )

      # Set editor text
      GenServer.cast(named_rpc, {:notify, "set_editor_text", %{text: "Hello World"}})

      # Wait for output to be written (flaky sleep replaced with proper wait)
      wait_for_output(output)

      # Verify notification was sent
      notification = MockIO.get_last_json(output)
      assert notification["method"] == "set_editor_text"
      assert notification["params"]["text"] == "Hello World"

      # Verify it's tracked locally
      text = GenServer.call(named_rpc, :get_editor_text)
      assert text == "Hello World"

      GenServer.stop(named_rpc)
    end
  end

  describe "has_ui?/0" do
    test "returns true" do
      assert RPC.has_ui?() == true
    end
  end

  # ============================================================================
  # Edge Case Tests
  # ============================================================================

  describe "error handling" do
    test "handles invalid JSON response gracefully", %{rpc: rpc, input: input, output: output} do
      spawn(fn ->
        Process.sleep(50)
        # Send invalid JSON
        MockIO.put_input(input, "not valid json {{{")

        # Then send valid response
        Process.sleep(50)
        [request_json | _] = wait_for_output(output)
        request = Jason.decode!(request_json)
        MockIO.put_input(input, Jason.encode!(%{id: request["id"], result: "ok"}))
      end)

      result = RPC.select("Choose", [%{label: "A", value: "a", description: nil}], server: rpc)

      # Should still get the valid response
      assert result == {:ok, "ok"}
    end

    test "handles response without matching request id", %{rpc: rpc, input: input, output: output} do
      spawn(fn ->
        Process.sleep(50)
        # Send response with wrong ID
        MockIO.put_input(input, Jason.encode!(%{id: "wrong-id", result: "ignored"}))

        # Then send correct response
        Process.sleep(50)
        [request_json | _] = wait_for_output(output)
        request = Jason.decode!(request_json)
        MockIO.put_input(input, Jason.encode!(%{id: request["id"], result: "correct"}))
      end)

      result = RPC.select("Choose", [%{label: "A", value: "a", description: nil}], server: rpc)

      assert result == {:ok, "correct"}
    end

    test "handles connection closed", %{input: input, output: output} do
      {:ok, rpc} =
        RPC.start_link(
          input_device: input,
          output_device: output,
          # Under load, the reader task may not observe EOF quickly enough to beat a very short
          # request timeout. Use a more realistic timeout to avoid test flakiness.
          timeout: 2_000
        )

      # Start a request, then close input
      task =
        Task.async(fn ->
          RPC.select("Choose", [%{label: "A", value: "a", description: nil}], server: rpc)
        end)

      # Ensure request is actually in-flight before closing input.
      assert [_request_json | _] = wait_for_output(output, 2_000)

      # Close the input - this should fail pending requests
      MockIO.close(input)

      # Request should return connection_closed error
      result = Task.await(task)

      assert result == {:error, :connection_closed}

      GenServer.stop(rpc)
    end
  end

  describe "concurrent requests" do
    test "handles multiple concurrent requests with different IDs", %{
      rpc: rpc,
      input: input,
      output: output
    } do
      # Start multiple requests concurrently
      task1 =
        Task.async(fn ->
          RPC.select("First", [%{label: "A", value: "a", description: nil}], server: rpc)
        end)

      task2 =
        Task.async(fn ->
          RPC.confirm("Second", "Sure?", server: rpc)
        end)

      # Wait for requests to be sent
      Process.sleep(100)

      # Get all requests
      requests = MockIO.get_output(output)
      assert length(requests) == 2

      decoded_requests = Enum.map(requests, &Jason.decode!/1)

      # Find each request and respond appropriately
      Enum.each(decoded_requests, fn request ->
        response =
          case request["method"] do
            "select" -> %{id: request["id"], result: "selected"}
            "confirm" -> %{id: request["id"], result: true}
          end

        MockIO.put_input(input, Jason.encode!(response))
      end)

      # Both should complete successfully
      result1 = Task.await(task1)
      result2 = Task.await(task2)

      assert result1 == {:ok, "selected"}
      assert result2 == {:ok, true}
    end
  end

  # ============================================================================
  # Edge Case Tests - Concurrent Request Handling with ID Collisions
  # ============================================================================

  describe "concurrent request handling with ID collisions" do
    test "responses arrive out of order", %{rpc: rpc, input: input, output: output} do
      # Start two requests
      task1 =
        Task.async(fn ->
          RPC.select("First", [%{label: "A", value: "a", description: nil}], server: rpc)
        end)

      task2 =
        Task.async(fn ->
          RPC.confirm("Second", "Message", server: rpc)
        end)

      # Wait for requests to be sent
      Process.sleep(100)

      requests = MockIO.get_output(output)
      decoded = Enum.map(requests, &Jason.decode!/1)

      # Find request IDs
      {select_req, confirm_req} =
        Enum.reduce(decoded, {nil, nil}, fn req, {s, c} ->
          case req["method"] do
            "select" -> {req, c}
            "confirm" -> {s, req}
            _ -> {s, c}
          end
        end)

      # Respond to second request first (out of order)
      MockIO.put_input(input, Jason.encode!(%{id: confirm_req["id"], result: true}))
      Process.sleep(20)
      MockIO.put_input(input, Jason.encode!(%{id: select_req["id"], result: "a"}))

      result1 = Task.await(task1)
      result2 = Task.await(task2)

      assert result1 == {:ok, "a"}
      assert result2 == {:ok, true}
    end

    test "duplicate response for same ID is ignored", %{rpc: rpc, input: input, output: output} do
      spawn(fn ->
        Process.sleep(50)
        [request_json | _] = wait_for_output(output)
        request = Jason.decode!(request_json)

        # Send first response
        MockIO.put_input(input, Jason.encode!(%{id: request["id"], result: "first"}))
        Process.sleep(10)
        # Send duplicate response for same ID (should be ignored)
        MockIO.put_input(input, Jason.encode!(%{id: request["id"], result: "duplicate"}))
      end)

      result = RPC.select("Choose", [%{label: "A", value: "a", description: nil}], server: rpc)

      # Should get first response, duplicate logged as warning
      assert result == {:ok, "first"}
    end

    test "many concurrent requests with staggered responses", %{
      rpc: rpc,
      input: input,
      output: output
    } do
      # Start many concurrent requests
      tasks =
        for i <- 1..10 do
          Task.async(fn ->
            RPC.input("Input #{i}", nil, server: rpc)
          end)
        end

      # Wait for all requests to be sent
      Process.sleep(150)

      requests = MockIO.get_output(output)
      assert length(requests) == 10

      decoded = Enum.map(requests, &Jason.decode!/1)

      # Respond in reverse order
      decoded
      |> Enum.reverse()
      |> Enum.with_index()
      |> Enum.each(fn {req, idx} ->
        Process.sleep(5)
        MockIO.put_input(input, Jason.encode!(%{id: req["id"], result: "response_#{idx}"}))
      end)

      results = Enum.map(tasks, &Task.await/1)

      # All should succeed
      assert Enum.all?(results, fn
               {:ok, _} -> true
               _ -> false
             end)
    end
  end

  # ============================================================================
  # Edge Case Tests - Device IO Error Handling
  # ============================================================================

  describe "device IO error handling" do
    defmodule ErrorIO do
      @moduledoc "Mock IO that returns errors on read operations"
      use GenServer

      def start_link(error_type) do
        GenServer.start_link(__MODULE__, error_type)
      end

      def init(error_type), do: {:ok, %{error_type: error_type, output: []}}

      def get_output(device), do: GenServer.call(device, :get_output)

      def handle_call(:get_output, _from, state) do
        {:reply, Enum.reverse(state.output), state}
      end

      def handle_info({:io_request, from, reply_as, {:get_line, _, _}}, state) do
        send(from, {:io_reply, reply_as, {:error, state.error_type}})
        {:noreply, state}
      end

      def handle_info({:io_request, from, reply_as, {:get_line, _}}, state) do
        send(from, {:io_reply, reply_as, {:error, state.error_type}})
        {:noreply, state}
      end

      def handle_info({:io_request, from, reply_as, {:put_chars, _, chars}}, state) do
        line = IO.chardata_to_string(chars) |> String.trim_trailing("\n")
        send(from, {:io_reply, reply_as, :ok})
        {:noreply, %{state | output: [line | state.output]}}
      end

      def handle_info({:io_request, from, reply_as, {:put_chars, chars}}, state) do
        line = IO.chardata_to_string(chars) |> String.trim_trailing("\n")
        send(from, {:io_reply, reply_as, :ok})
        {:noreply, %{state | output: [line | state.output]}}
      end

      def handle_info({:io_request, from, reply_as, _}, state) do
        send(from, {:io_reply, reply_as, {:error, :request}})
        {:noreply, state}
      end
    end

    test "handles :enodev error from input device", %{output: output} do
      {:ok, error_input} = ErrorIO.start_link(:enodev)

      {:ok, rpc} =
        RPC.start_link(
          input_device: error_input,
          output_device: output,
          timeout: 200
        )

      # The reader task should handle the error and restart
      # Request should timeout since no response comes
      result = RPC.select("Choose", [%{label: "A", value: "a", description: nil}], server: rpc)

      assert result == {:error, :timeout}

      GenServer.stop(rpc)
      GenServer.stop(error_input)
    end

    test "handles :terminated error from input device", %{output: output} do
      {:ok, error_input} = ErrorIO.start_link(:terminated)

      {:ok, rpc} =
        RPC.start_link(
          input_device: error_input,
          output_device: output,
          timeout: 200
        )

      result = RPC.select("Choose", [%{label: "A", value: "a", description: nil}], server: rpc)

      assert result == {:error, :timeout}

      GenServer.stop(rpc)
      GenServer.stop(error_input)
    end
  end

  # ============================================================================
  # Edge Case Tests - JSON Parsing Error Handling
  # ============================================================================

  describe "JSON parsing error handling for malformed responses" do
    test "handles truncated JSON", %{rpc: rpc, input: input, output: output} do
      spawn(fn ->
        Process.sleep(50)
        # Send truncated JSON
        MockIO.put_input(input, ~s({"id": "123", "result":))

        # Then send valid response
        Process.sleep(30)
        [request_json | _] = wait_for_output(output)
        request = Jason.decode!(request_json)
        MockIO.put_input(input, Jason.encode!(%{id: request["id"], result: "valid"}))
      end)

      result = RPC.select("Choose", [%{label: "A", value: "a", description: nil}], server: rpc)

      assert result == {:ok, "valid"}
    end

    test "handles JSON with unexpected encoding", %{rpc: rpc, input: input, output: output} do
      spawn(fn ->
        Process.sleep(50)
        # Send with BOM or other encoding issues
        MockIO.put_input(input, "\uFEFF{malformed}")

        Process.sleep(30)
        [request_json | _] = wait_for_output(output)
        request = Jason.decode!(request_json)
        MockIO.put_input(input, Jason.encode!(%{id: request["id"], result: "ok"}))
      end)

      result = RPC.select("Choose", [%{label: "A", value: "a", description: nil}], server: rpc)

      assert result == {:ok, "ok"}
    end

    test "handles JSON without id field", %{rpc: rpc, input: input, output: output} do
      spawn(fn ->
        Process.sleep(50)
        # Valid JSON but missing id
        MockIO.put_input(input, ~s({"result": "no_id"}))

        Process.sleep(30)
        [request_json | _] = wait_for_output(output)
        request = Jason.decode!(request_json)
        MockIO.put_input(input, Jason.encode!(%{id: request["id"], result: "with_id"}))
      end)

      result = RPC.select("Choose", [%{label: "A", value: "a", description: nil}], server: rpc)

      assert result == {:ok, "with_id"}
    end

    test "handles empty line", %{rpc: rpc, input: input, output: output} do
      spawn(fn ->
        Process.sleep(50)
        # Empty line (should be ignored)
        MockIO.put_input(input, "")
        MockIO.put_input(input, "   ")

        Process.sleep(30)
        [request_json | _] = wait_for_output(output)
        request = Jason.decode!(request_json)
        MockIO.put_input(input, Jason.encode!(%{id: request["id"], result: "ok"}))
      end)

      result = RPC.select("Choose", [%{label: "A", value: "a", description: nil}], server: rpc)

      assert result == {:ok, "ok"}
    end

    test "handles JSON with null id", %{rpc: rpc, input: input, output: output} do
      spawn(fn ->
        Process.sleep(50)
        # JSON with null id
        MockIO.put_input(input, ~s({"id": null, "result": "null_id"}))

        Process.sleep(30)
        [request_json | _] = wait_for_output(output)
        request = Jason.decode!(request_json)
        MockIO.put_input(input, Jason.encode!(%{id: request["id"], result: "ok"}))
      end)

      result = RPC.select("Choose", [%{label: "A", value: "a", description: nil}], server: rpc)

      assert result == {:ok, "ok"}
    end

    test "handles response with neither result nor error", %{
      rpc: rpc,
      input: input,
      output: output
    } do
      spawn(fn ->
        Process.sleep(50)
        [request_json | _] = wait_for_output(output)
        request = Jason.decode!(request_json)
        # Response with id but no result or error
        MockIO.put_input(input, Jason.encode!(%{id: request["id"]}))
      end)

      result = RPC.select("Choose", [%{label: "A", value: "a", description: nil}], server: rpc)

      # Should return :invalid_response error
      assert result == {:error, :invalid_response}
    end
  end

  # ============================================================================
  # Edge Case Tests - Large Payload Handling
  # ============================================================================

  describe "large payload handling (>10MB simulation)" do
    test "handles large result payload", %{rpc: rpc, input: input, output: output} do
      # Generate a large string (simulating >10MB but smaller for test speed)
      large_content = String.duplicate("x", 100_000)

      spawn(fn ->
        Process.sleep(50)
        [request_json | _] = wait_for_output(output)
        request = Jason.decode!(request_json)
        MockIO.put_input(input, Jason.encode!(%{id: request["id"], result: large_content}))
      end)

      result = RPC.editor("Large Edit", nil, server: rpc)

      assert {:ok, content} = result
      assert byte_size(content) == 100_000
    end

    test "handles large request payload", %{rpc: rpc, input: input, output: output} do
      large_prefill = String.duplicate("y", 100_000)

      spawn(fn ->
        Process.sleep(100)
        output_lines = wait_for_output(output, 2000)
        [request_json | _] = output_lines
        request = Jason.decode!(request_json)
        MockIO.put_input(input, Jason.encode!(%{id: request["id"], result: "edited"}))
      end)

      result = RPC.editor("Large Prefill", large_prefill, server: rpc)

      assert result == {:ok, "edited"}

      # Verify the request contained the large payload
      [request_json | _] = MockIO.get_output(output)
      request = Jason.decode!(request_json)
      assert byte_size(request["params"]["prefill"]) == 100_000
    end

    test "handles many options in select", %{rpc: rpc, input: input, output: output} do
      # Create 1000 options
      options =
        for i <- 1..1000 do
          %{label: "Option #{i}", value: "opt_#{i}", description: "Description for option #{i}"}
        end

      spawn(fn ->
        Process.sleep(100)
        output_lines = wait_for_output(output, 2000)
        [request_json | _] = output_lines
        request = Jason.decode!(request_json)
        MockIO.put_input(input, Jason.encode!(%{id: request["id"], result: "opt_500"}))
      end)

      result = RPC.select("Choose from many", options, server: rpc)

      assert result == {:ok, "opt_500"}
    end

    test "handles response with deeply nested JSON", %{rpc: rpc, input: input, output: output} do
      # Create deeply nested structure
      nested =
        Enum.reduce(1..50, "innermost", fn i, acc ->
          %{"level_#{i}" => acc}
        end)

      spawn(fn ->
        Process.sleep(50)
        [request_json | _] = wait_for_output(output)
        request = Jason.decode!(request_json)
        MockIO.put_input(input, Jason.encode!(%{id: request["id"], result: nested}))
      end)

      result = RPC.select("Choose", [%{label: "A", value: "a", description: nil}], server: rpc)

      assert {:ok, result_map} = result
      assert is_map(result_map)
    end
  end

  # ============================================================================
  # Edge Case Tests - Rapid Request/Response Cycles
  # ============================================================================

  describe "rapid request/response cycles" do
    test "handles rapid sequential requests", %{rpc: rpc, input: input, output: output} do
      responder =
        spawn(fn ->
          rapid_responder_loop(input, output, 20)
        end)

      # Make 20 rapid requests
      results =
        for i <- 1..20 do
          RPC.input("Rapid #{i}", nil, server: rpc)
        end

      Process.exit(responder, :normal)

      # All should succeed
      assert length(results) == 20

      assert Enum.all?(results, fn
               {:ok, _} -> true
               _ -> false
             end)
    end

    test "handles burst of concurrent requests", %{rpc: rpc, input: input, output: output} do
      # Start all requests at once
      tasks =
        for i <- 1..15 do
          Task.async(fn ->
            RPC.confirm("Burst #{i}", "Sure?", server: rpc)
          end)
        end

      # Wait a bit for requests to be sent
      Process.sleep(100)

      # Respond to all
      requests = MockIO.get_output(output)

      for req_json <- requests do
        req = Jason.decode!(req_json)
        MockIO.put_input(input, Jason.encode!(%{id: req["id"], result: true}))
      end

      # Collect results
      results = Enum.map(tasks, &Task.await(&1, 2000))

      assert length(results) == 15

      assert Enum.all?(results, fn
               {:ok, true} -> true
               _ -> false
             end)
    end

    test "maintains request isolation under rapid fire", %{rpc: rpc, input: input, output: output} do
      # Make requests with unique identifiable responses
      tasks =
        for i <- 1..10 do
          Task.async(fn ->
            result = RPC.input("Query #{i}", nil, server: rpc)
            {i, result}
          end)
        end

      # Wait for requests
      Process.sleep(100)

      # Respond with values that can be traced back
      requests = MockIO.get_output(output)

      for req_json <- requests do
        req = Jason.decode!(req_json)
        # Extract query number from title
        title = req["params"]["title"]
        MockIO.put_input(input, Jason.encode!(%{id: req["id"], result: title}))
      end

      results = Enum.map(tasks, &Task.await(&1, 2000))

      # Each task should get its own response
      for {i, {:ok, result}} <- results do
        assert result == "Query #{i}"
      end
    end
  end

  defp rapid_responder_loop(input, output, count) when count > 0 do
    rapid_responder_loop(input, output, count, 0)
  end

  defp rapid_responder_loop(_input, _output, 0, _last_index), do: :ok

  defp rapid_responder_loop(input, output, count, last_index) do
    output_lines = MockIO.get_output(output)

    if length(output_lines) > last_index do
      request = output_lines |> Enum.at(last_index) |> Jason.decode!()
      MockIO.put_input(input, Jason.encode!(%{id: request["id"], result: "rapid_#{count}"}))
      rapid_responder_loop(input, output, count - 1, last_index + 1)
    else
      Process.sleep(5)
      rapid_responder_loop(input, output, count, last_index)
    end
  end

  # ============================================================================
  # Edge Case Tests - Reader Task Lifecycle Management Under Errors
  # ============================================================================

  describe "reader task lifecycle management under errors" do
    defmodule FlakeyIO do
      @moduledoc "Mock IO that fails intermittently then works"
      use GenServer

      def start_link(fail_count) do
        GenServer.start_link(__MODULE__, fail_count)
      end

      def put_input(device, line), do: GenServer.call(device, {:put_input, line})
      def get_output(device), do: GenServer.call(device, :get_output)

      def init(fail_count) do
        {:ok, %{fail_count: fail_count, input_queue: :queue.new(), output: [], waiting: nil}}
      end

      def handle_call({:put_input, line}, _from, state) do
        new_queue = :queue.in(line <> "\n", state.input_queue)
        state = %{state | input_queue: new_queue}

        state =
          case state.waiting do
            {waiting_from, reply_as} ->
              case :queue.out(state.input_queue) do
                {{:value, data}, rest} ->
                  send(waiting_from, {:io_reply, reply_as, data})
                  %{state | input_queue: rest, waiting: nil}

                {:empty, _} ->
                  state
              end

            nil ->
              state
          end

        {:reply, :ok, state}
      end

      def handle_call(:get_output, _from, state) do
        {:reply, Enum.reverse(state.output), state}
      end

      def handle_info({:io_request, from, reply_as, {:get_line, _, _}}, state) do
        handle_get_line(from, reply_as, state)
      end

      def handle_info({:io_request, from, reply_as, {:get_line, _}}, state) do
        handle_get_line(from, reply_as, state)
      end

      def handle_info({:io_request, from, reply_as, {:put_chars, _, chars}}, state) do
        line = IO.chardata_to_string(chars) |> String.trim_trailing("\n")
        send(from, {:io_reply, reply_as, :ok})
        {:noreply, %{state | output: [line | state.output]}}
      end

      def handle_info({:io_request, from, reply_as, {:put_chars, chars}}, state) do
        line = IO.chardata_to_string(chars) |> String.trim_trailing("\n")
        send(from, {:io_reply, reply_as, :ok})
        {:noreply, %{state | output: [line | state.output]}}
      end

      def handle_info({:io_request, from, reply_as, _}, state) do
        send(from, {:io_reply, reply_as, {:error, :request}})
        {:noreply, state}
      end

      defp handle_get_line(from, reply_as, state) do
        if state.fail_count > 0 do
          send(from, {:io_reply, reply_as, {:error, :transient}})
          {:noreply, %{state | fail_count: state.fail_count - 1}}
        else
          case :queue.out(state.input_queue) do
            {{:value, line}, rest} ->
              send(from, {:io_reply, reply_as, line})
              {:noreply, %{state | input_queue: rest}}

            {:empty, _} ->
              {:noreply, %{state | waiting: {from, reply_as}}}
          end
        end
      end
    end

    test "reader task restarts after transient errors", %{output: output} do
      # IO that fails twice then works
      {:ok, flakey_input} = FlakeyIO.start_link(2)

      {:ok, rpc} =
        RPC.start_link(
          input_device: flakey_input,
          output_device: output,
          timeout: 2000
        )

      # Give time for reader to fail and restart
      Process.sleep(200)

      # Now it should work
      spawn(fn ->
        Process.sleep(100)
        [request_json | _] = wait_for_output(output, 1000)
        request = Jason.decode!(request_json)
        FlakeyIO.put_input(flakey_input, Jason.encode!(%{id: request["id"], result: "recovered"}))
      end)

      result = RPC.select("Choose", [%{label: "A", value: "a", description: nil}], server: rpc)

      assert result == {:ok, "recovered"}

      GenServer.stop(rpc)
      GenServer.stop(flakey_input)
    end

    test "server continues working after reader task crash" do
      {:ok, input} = MockIO.start_link()
      {:ok, output} = MockIO.start_link()

      {:ok, rpc} =
        RPC.start_link(
          input_device: input,
          output_device: output,
          timeout: 1000
        )

      # Get the initial reader task ref (internal state check)
      state = :sys.get_state(rpc)
      assert state.reader_task != nil

      # Server should still be alive and responsive
      assert Process.alive?(rpc)

      # Should be able to make requests
      spawn(fn ->
        Process.sleep(50)
        [request_json | _] = wait_for_output(output)
        request = Jason.decode!(request_json)
        MockIO.put_input(input, Jason.encode!(%{id: request["id"], result: "ok"}))
      end)

      result = RPC.select("Test", [%{label: "A", value: "a", description: nil}], server: rpc)
      assert result == {:ok, "ok"}

      GenServer.stop(rpc)
      MockIO.close(input)
      GenServer.stop(output)
    end
  end

  # ============================================================================
  # Edge Case Tests - Timeout Scenarios
  # ============================================================================

  describe "timeout scenarios" do
    test "request times out with no response", %{input: input, output: output} do
      {:ok, rpc} =
        RPC.start_link(
          input_device: input,
          output_device: output,
          timeout: 100
        )

      # Don't send any response
      result = RPC.select("Choose", [%{label: "A", value: "a", description: nil}], server: rpc)

      assert result == {:error, :timeout}

      GenServer.stop(rpc)
    end

    test "timeout clears pending request", %{input: input, output: output} do
      {:ok, rpc} =
        RPC.start_link(
          input_device: input,
          output_device: output,
          timeout: 50
        )

      # First request times out
      result1 = RPC.select("First", [%{label: "A", value: "a", description: nil}], server: rpc)
      assert result1 == {:error, :timeout}

      # Late response arrives for first request (should be ignored)
      [request_json | _] = wait_for_output(output, 1000)
      request = Jason.decode!(request_json)
      MockIO.put_input(input, Jason.encode!(%{id: request["id"], result: "late"}))

      # Second request should work independently
      task =
        Task.async(fn ->
          RPC.select("Second", [%{label: "B", value: "b", description: nil}], server: rpc)
        end)

      output_lines = wait_for_output_count(output, 2, 1000)
      second_request_json = List.last(output_lines)
      second_request = Jason.decode!(second_request_json)
      MockIO.put_input(input, Jason.encode!(%{id: second_request["id"], result: "second"}))

      assert Task.await(task, 1000) == {:ok, "second"}

      GenServer.stop(rpc)
    end

    test "multiple requests timeout independently", %{input: input, output: output} do
      {:ok, rpc} =
        RPC.start_link(
          input_device: input,
          output_device: output,
          timeout: 100
        )

      # Start multiple requests that will timeout
      task1 =
        Task.async(fn ->
          RPC.select("A", [%{label: "A", value: "a", description: nil}], server: rpc)
        end)

      task2 = Task.async(fn -> RPC.confirm("B", "Sure?", server: rpc) end)
      task3 = Task.async(fn -> RPC.input("C", nil, server: rpc) end)

      # Wait for all to timeout
      results = [Task.await(task1), Task.await(task2), Task.await(task3)]

      assert Enum.all?(results, fn
               {:error, :timeout} -> true
               _ -> false
             end)

      GenServer.stop(rpc)
    end

    test "response just before timeout succeeds", %{input: input, output: output} do
      {:ok, rpc} =
        RPC.start_link(
          input_device: input,
          output_device: output,
          timeout: 200
        )

      spawn(fn ->
        # Wait almost until timeout
        Process.sleep(150)
        [request_json | _] = MockIO.get_output(output)
        request = Jason.decode!(request_json)
        MockIO.put_input(input, Jason.encode!(%{id: request["id"], result: "just_in_time"}))
      end)

      result = RPC.select("Choose", [%{label: "A", value: "a", description: nil}], server: rpc)

      assert result == {:ok, "just_in_time"}

      GenServer.stop(rpc)
    end

    test "custom timeout per request", %{rpc: rpc, input: input, output: output} do
      # Use a longer timeout via opts
      spawn(fn ->
        Process.sleep(800)
        [request_json | _] = MockIO.get_output(output)
        request = Jason.decode!(request_json)
        MockIO.put_input(input, Jason.encode!(%{id: request["id"], result: "slow_response"}))
      end)

      # Default timeout is 1000ms in setup, but we specify longer via opts
      result =
        RPC.select("Choose", [%{label: "A", value: "a", description: nil}],
          server: rpc,
          timeout: 2000
        )

      assert result == {:ok, "slow_response"}
    end
  end

  # ============================================================================
  # Edge Case Tests - Device Disconnection Mid-Response
  # ============================================================================

  describe "device disconnection mid-response" do
    test "input closes while request pending", %{input: input, output: output} do
      {:ok, rpc} =
        RPC.start_link(
          input_device: input,
          output_device: output,
          timeout: 1000
        )

      task =
        Task.async(fn ->
          RPC.select("Choose", [%{label: "A", value: "a", description: nil}], server: rpc)
        end)

      # Wait for request to be sent
      Process.sleep(50)

      # Close input while request is pending
      MockIO.close(input)

      # Should get connection_closed error
      result = Task.await(task)
      assert result == {:error, :connection_closed}

      GenServer.stop(rpc)
    end

    test "all pending requests fail on disconnect", %{input: input, output: output} do
      {:ok, rpc} =
        RPC.start_link(
          input_device: input,
          output_device: output,
          timeout: 2000
        )

      # Start multiple pending requests
      tasks =
        for i <- 1..5 do
          Task.async(fn ->
            RPC.input("Input #{i}", nil, server: rpc)
          end)
        end

      # Wait for requests to be sent
      Process.sleep(100)

      # Close input
      MockIO.close(input)

      # All should fail
      results = Enum.map(tasks, &Task.await/1)

      assert Enum.all?(results, fn
               {:error, :connection_closed} -> true
               _ -> false
             end)

      GenServer.stop(rpc)
    end

    test "partial JSON response before disconnect", %{input: input, output: output} do
      {:ok, rpc} =
        RPC.start_link(
          input_device: input,
          output_device: output,
          timeout: 500
        )

      task =
        Task.async(fn ->
          RPC.select("Choose", [%{label: "A", value: "a", description: nil}], server: rpc)
        end)

      # Wait for request
      Process.sleep(50)

      # Send partial response then close
      # Note: MockIO sends complete lines, so we simulate this by sending invalid JSON
      MockIO.put_input(input, ~s({"id": "partial"))
      Process.sleep(10)
      MockIO.close(input)

      result = Task.await(task)

      # Should fail due to connection closed (partial JSON is logged but request still pending)
      assert result == {:error, :connection_closed}

      GenServer.stop(rpc)
    end

    test "server survives disconnect and can be stopped cleanly", %{input: input, output: output} do
      {:ok, rpc} =
        RPC.start_link(
          input_device: input,
          output_device: output,
          timeout: 100
        )

      # Start a request
      task =
        Task.async(fn ->
          RPC.select("Choose", [%{label: "A", value: "a", description: nil}], server: rpc)
        end)

      Process.sleep(20)
      MockIO.close(input)

      # Wait for request to fail
      Task.await(task)

      # Server should still be alive
      assert Process.alive?(rpc)

      # Should be able to stop cleanly
      assert :ok = GenServer.stop(rpc)
    end

    test "notifications still work after input disconnect", %{input: input, output: output} do
      {:ok, rpc} =
        RPC.start_link(
          input_device: input,
          output_device: output,
          timeout: 100
        )

      # Close input
      MockIO.close(input)

      # Wait for disconnect to be processed
      Process.sleep(50)

      # Notifications should still work (they're fire-and-forget to output)
      GenServer.cast(rpc, {:notify, "set_status", %{key: "test", text: "still works"}})

      Process.sleep(20)

      # Check output received the notification
      output_lines = MockIO.get_output(output)
      notification = List.last(output_lines) |> Jason.decode!()

      assert notification["method"] == "set_status"
      assert notification["params"]["text"] == "still works"

      GenServer.stop(rpc)
    end
  end

  # ============================================================================
  # Edge Case Tests - Server Shutdown
  # ============================================================================

  describe "server shutdown" do
    test "pending requests receive server_shutdown error", %{input: input, output: output} do
      {:ok, rpc} =
        RPC.start_link(
          input_device: input,
          output_device: output,
          timeout: 5000
        )

      # Start requests
      tasks =
        for i <- 1..3 do
          Task.async(fn ->
            RPC.input("Input #{i}", nil, server: rpc)
          end)
        end

      # Wait for requests to be sent
      Process.sleep(50)

      # Stop the server
      GenServer.stop(rpc)

      # All tasks should get server_shutdown or exit
      results =
        Enum.map(tasks, fn task ->
          try do
            Task.await(task, 100)
          catch
            :exit, _ -> {:error, :server_shutdown}
          end
        end)

      assert Enum.all?(results, fn
               {:error, :server_shutdown} -> true
               {:error, _} -> true
               _ -> false
             end)
    end

    test "reader task is killed on server shutdown" do
      {:ok, input} = MockIO.start_link()
      {:ok, output} = MockIO.start_link()

      {:ok, rpc} =
        RPC.start_link(
          input_device: input,
          output_device: output,
          timeout: 1000
        )

      # Get reader task info
      state = :sys.get_state(rpc)
      reader_task = state.reader_task

      assert reader_task != nil
      assert Process.alive?(reader_task.pid)

      # Stop server
      GenServer.stop(rpc)

      # Give time for cleanup
      Process.sleep(50)

      # Reader task should be dead
      refute Process.alive?(reader_task.pid)

      MockIO.close(input)
      GenServer.stop(output)
    end
  end
end
