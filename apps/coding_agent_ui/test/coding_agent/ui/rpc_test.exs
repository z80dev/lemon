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
      if Process.alive?(rpc), do: GenServer.stop(rpc)
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
          timeout: 500
        )

      # Start a request, then close input
      task =
        Task.async(fn ->
          RPC.select("Choose", [%{label: "A", value: "a", description: nil}], server: rpc)
        end)

      # Give it time to send request and start waiting
      Process.sleep(50)

      # Close the input - this should fail pending requests
      MockIO.close(input)

      # Request should return connection_closed error
      result = Task.await(task)

      assert result == {:error, :connection_closed}

      GenServer.stop(rpc)
    end
  end

  describe "concurrent requests" do
    test "handles multiple concurrent requests with different IDs", %{rpc: rpc, input: input, output: output} do
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
end
