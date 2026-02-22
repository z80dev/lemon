defmodule CodingAgent.UI.RPC do
  @moduledoc """
  RPC UI adapter for CodingAgent that communicates via JSON over stdin/stdout.

  This module implements the `CodingAgent.UI` behaviour and enables communication
  with external UI processes through a JSON-based protocol.

  ## Protocol

  ### Requests (sent to stdout)
  ```json
  {"id": "uuid", "method": "select|confirm|input|editor", "params": {...}}
  ```

  ### Responses (received from stdin)
  ```json
  {"id": "uuid", "result": ...}
  ```
  or
  ```json
  {"id": "uuid", "error": "message"}
  ```

  ### Notifications (sent to stdout, no response expected)
  ```json
  {"method": "notify|set_status|set_widget|set_working_message|set_title|set_editor_text", "params": {...}}
  ```

  ## Configuration

  - `:timeout` - Response timeout in milliseconds (default: 30_000)
  - `:input_device` - IO device for reading input (default: :stdio)
  - `:output_device` - IO device for writing output (default: :stdio)

  ## Usage

  ```elixir
  {:ok, pid} = CodingAgent.UI.RPC.start_link(name: MyUI)
  {:ok, selected} = CodingAgent.UI.RPC.select(pid, "Choose option", [%{label: "A", value: "a"}])
  ```
  """

  use GenServer

  @behaviour CodingAgent.UI

  require Logger

  @default_timeout 30_000

  # ============================================================================
  # Types
  # ============================================================================

  @type state :: %{
          pending_requests: %{String.t() => {pid(), reference()}},
          timeout: pos_integer(),
          input_device: atom() | pid(),
          output_device: atom() | pid(),
          reader_task: Task.t() | nil,
          input_closed: boolean(),
          editor_text: String.t()
        }

  # ============================================================================
  # Client API
  # ============================================================================

  @doc """
  Starts the RPC UI server.

  ## Options

  - `:name` - GenServer name (optional)
  - `:timeout` - Response timeout in milliseconds (default: 30_000)
  - `:input_device` - IO device for reading input (default: :stdio)
  - `:output_device` - IO device for writing output (default: :stdio)
  """
  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name)
    server_opts = if name, do: [name: name], else: []
    GenServer.start_link(__MODULE__, opts, server_opts)
  end

  @doc """
  Stops the RPC UI server.
  """
  def stop(server) do
    GenServer.stop(server)
  end

  # ============================================================================
  # CodingAgent.UI Behaviour Implementation
  # ============================================================================

  @impl CodingAgent.UI
  def select(title, options, opts \\ []) do
    server = get_server(opts)
    clean_opts = clean_opts(opts)

    GenServer.call(
      server,
      {:request, "select", %{title: title, options: options, opts: clean_opts}},
      get_timeout(opts)
    )
  end

  @impl CodingAgent.UI
  def confirm(title, message, opts \\ []) do
    server = get_server(opts)
    clean_opts = clean_opts(opts)

    GenServer.call(
      server,
      {:request, "confirm", %{title: title, message: message, opts: clean_opts}},
      get_timeout(opts)
    )
  end

  @impl CodingAgent.UI
  def input(title, placeholder \\ nil, opts \\ []) do
    server = get_server(opts)
    clean_opts = clean_opts(opts)

    GenServer.call(
      server,
      {:request, "input", %{title: title, placeholder: placeholder, opts: clean_opts}},
      get_timeout(opts)
    )
  end

  @impl CodingAgent.UI
  def editor(title, prefill \\ nil, opts \\ []) do
    server = get_server(opts)
    clean_opts = clean_opts(opts)

    GenServer.call(
      server,
      {:request, "editor", %{title: title, prefill: prefill, opts: clean_opts}},
      get_timeout(opts)
    )
  end

  @impl CodingAgent.UI
  def notify(message, type) do
    server = get_server([])
    GenServer.cast(server, {:notify, "notify", %{message: message, type: type}})
    :ok
  end

  @impl CodingAgent.UI
  def set_status(key, text) do
    server = get_server([])
    GenServer.cast(server, {:notify, "set_status", %{key: key, text: text}})
    :ok
  end

  @impl CodingAgent.UI
  def set_widget(key, content, opts \\ []) do
    server = get_server([])
    GenServer.cast(server, {:notify, "set_widget", %{key: key, content: content, opts: opts}})
    :ok
  end

  @impl CodingAgent.UI
  def set_working_message(message) do
    server = get_server([])
    GenServer.cast(server, {:notify, "set_working_message", %{message: message}})
    :ok
  end

  @impl CodingAgent.UI
  def set_title(title) do
    server = get_server([])
    GenServer.cast(server, {:notify, "set_title", %{title: title}})
    :ok
  end

  @impl CodingAgent.UI
  def set_editor_text(text) do
    server = get_server([])
    GenServer.cast(server, {:notify, "set_editor_text", %{text: text}})
    :ok
  end

  @impl CodingAgent.UI
  def get_editor_text do
    server = get_server([])
    GenServer.call(server, :get_editor_text)
  end

  @impl CodingAgent.UI
  def has_ui? do
    true
  end

  # ============================================================================
  # Server Implementation
  # ============================================================================

  @impl GenServer
  def init(opts) do
    timeout = Keyword.get(opts, :timeout, @default_timeout)
    input_device = Keyword.get(opts, :input_device, :stdio)
    output_device = Keyword.get(opts, :output_device, :stdio)

    state = %{
      pending_requests: %{},
      timeout: timeout,
      input_device: input_device,
      output_device: output_device,
      reader_task: nil,
      input_closed: false,
      editor_text: ""
    }

    # Start the input reader task
    state = start_reader_task(state)

    {:ok, state}
  end

  @impl GenServer
  def handle_call({:request, _method, _params}, _from, %{input_closed: true} = state) do
    {:reply, {:error, :connection_closed}, state}
  end

  @impl GenServer
  def handle_call({:request, method, params}, from, state) do
    request_id = UUID.uuid4()

    request = %{
      id: request_id,
      method: method,
      params: params
    }

    # Send request to output
    send_json(state.output_device, request)

    # Set up timeout
    timer_ref = Process.send_after(self(), {:timeout, request_id}, state.timeout)

    # Store pending request
    pending = Map.put(state.pending_requests, request_id, {from, timer_ref})

    {:noreply, %{state | pending_requests: pending}}
  end

  @impl GenServer
  def handle_call(:get_editor_text, _from, state) do
    {:reply, state.editor_text, state}
  end

  @impl GenServer
  def handle_cast({:notify, method, params}, state) do
    notification = %{
      method: method,
      params: params
    }

    send_json(state.output_device, notification)

    # Also track editor_text locally if it's set_editor_text
    state =
      if method == "set_editor_text" do
        %{state | editor_text: params.text || ""}
      else
        state
      end

    {:noreply, state}
  end

  @impl GenServer
  def handle_info({:response, json_line}, state) do
    case Jason.decode(json_line) do
      {:ok, %{"id" => id} = response} ->
        handle_response(id, response, state)

      {:ok, _invalid} ->
        Logger.warning("[RPC UI] Received JSON without id: #{inspect(json_line)}")
        {:noreply, state}

      {:error, reason} ->
        Logger.warning(
          "[RPC UI] Failed to parse JSON: #{inspect(reason)}, line: #{inspect(json_line)}"
        )

        {:noreply, state}
    end
  end

  @impl GenServer
  def handle_info({:timeout, request_id}, state) do
    case Map.pop(state.pending_requests, request_id) do
      {{from, _timer_ref}, pending} ->
        GenServer.reply(from, {:error, :timeout})
        {:noreply, %{state | pending_requests: pending}}

      {nil, _} ->
        # Request already completed
        {:noreply, state}
    end
  end

  @impl GenServer
  def handle_info({:reader_error, reason}, state) do
    Logger.error("[RPC UI] Reader error: #{inspect(reason)}")
    # Try to restart the reader
    state = start_reader_task(state)
    {:noreply, state}
  end

  @impl GenServer
  def handle_info({:reader_closed}, state) do
    Logger.warning("[RPC UI] Input stream closed")
    # Fail all pending requests - don't restart reader when closed
    state = fail_all_pending(state, :connection_closed)
    {:noreply, %{state | reader_task: nil, input_closed: true}}
  end

  @impl GenServer
  def handle_info({:DOWN, ref, :process, _pid, :normal}, %{reader_task: %Task{ref: ref}} = state) do
    # Reader task completed normally (e.g., EOF) - don't restart
    {:noreply, %{state | reader_task: nil}}
  end

  @impl GenServer
  def handle_info({ref, _result}, state) when is_reference(ref) do
    # Task completion - ignore
    {:noreply, state}
  end

  @impl GenServer
  def handle_info({:DOWN, _ref, :process, _pid, reason}, state) when reason != :normal do
    # Task died abnormally - try to restart
    state = start_reader_task(state)
    {:noreply, state}
  end

  @impl GenServer
  def handle_info({:DOWN, _ref, :process, _pid, :normal}, state) do
    # Task completed normally - don't restart
    {:noreply, %{state | reader_task: nil}}
  end

  @impl GenServer
  def terminate(_reason, state) do
    # Cancel reader task if running
    if state.reader_task do
      Task.shutdown(state.reader_task, :brutal_kill)
    end

    # Fail all pending requests
    fail_all_pending(state, :server_shutdown)

    :ok
  end

  # ============================================================================
  # Private Functions
  # ============================================================================

  defp get_server(opts) do
    Keyword.get(opts, :server, __MODULE__)
  end

  defp get_timeout(opts) do
    Keyword.get(opts, :timeout, @default_timeout + 5000)
  end

  # Remove internal options that shouldn't be sent over the wire
  defp clean_opts(opts) do
    opts
    |> Keyword.drop([:server, :timeout])
    |> Enum.into(%{})
  end

  defp send_json(device, data) do
    json = Jason.encode!(data)
    IO.puts(device, json)
  end

  defp start_reader_task(state) do
    parent = self()
    input_device = state.input_device

    task =
      Task.async(fn ->
        read_input_loop(parent, input_device)
      end)

    %{state | reader_task: task}
  end

  defp read_input_loop(parent, device) do
    case IO.gets(device, "") do
      :eof ->
        send(parent, {:reader_closed})

      {:error, reason} ->
        send(parent, {:reader_error, reason})

      line when is_binary(line) ->
        trimmed = String.trim(line)

        if trimmed != "" do
          send(parent, {:response, trimmed})
        end

        read_input_loop(parent, device)
    end
  end

  defp handle_response(id, response, state) do
    case Map.pop(state.pending_requests, id) do
      {{from, timer_ref}, pending} ->
        # Cancel timeout timer
        Process.cancel_timer(timer_ref)

        # Send reply
        result = parse_response(response)
        GenServer.reply(from, result)

        {:noreply, %{state | pending_requests: pending}}

      {nil, _} ->
        Logger.warning("[RPC UI] Received response for unknown request: #{id}")
        {:noreply, state}
    end
  end

  defp parse_response(%{"result" => result}) do
    {:ok, result}
  end

  defp parse_response(%{"error" => error}) do
    {:error, error}
  end

  defp parse_response(_) do
    {:error, :invalid_response}
  end

  defp fail_all_pending(state, reason) do
    Enum.each(state.pending_requests, fn {_id, {from, timer_ref}} ->
      Process.cancel_timer(timer_ref)
      GenServer.reply(from, {:error, reason})
    end)

    %{state | pending_requests: %{}}
  end
end
