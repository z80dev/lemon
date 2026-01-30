defmodule CodingAgent.UI.DebugRPC do
  @moduledoc """
  UI adapter for integration with the debug_agent_rpc.exs protocol.

  Unlike `CodingAgent.UI.RPC` which manages its own stdin/stdout communication,
  this adapter is designed to share the same JSON line protocol with the debug
  agent script. It:
  - Sends `ui_request` messages to stdout (via the debug protocol)
  - Receives `ui_response` messages routed from the debug script's input handler

  ## Protocol

  ### Requests (sent to stdout)
  ```json
  {"type":"ui_request","id":"uuid","method":"select|confirm|input|editor","params":{...}}
  ```

  ### Responses (routed from stdin by debug script)
  ```json
  {"type":"ui_response","id":"uuid","result":...,"error":null}
  ```

  ### Notifications (sent to stdout)
  ```json
  {"type":"ui_notify","params":{"message":"...","notify_type":"info"}}
  {"type":"ui_status","params":{"key":"...","text":"..."}}
  {"type":"ui_widget","params":{"key":"...","content":"...","opts":{}}}
  {"type":"ui_working","params":{"message":"..."}}
  {"type":"ui_set_title","params":{"title":"..."}}
  {"type":"ui_set_editor_text","params":{"text":"..."}}
  ```

  ## Usage

  The debug script starts this adapter and routes ui_response messages to it:

  ```elixir
  {:ok, ui_pid} = CodingAgent.UI.DebugRPC.start_link(name: CodingAgent.UI.DebugRPC)
  ui_context = CodingAgent.UI.Context.new(CodingAgent.UI.DebugRPC)

  # When receiving ui_response from stdin:
  CodingAgent.UI.DebugRPC.handle_response(ui_pid, response_map)
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
          output_device: atom() | pid(),
          editor_text: String.t()
        }

  # ============================================================================
  # Client API
  # ============================================================================

  @doc """
  Starts the DebugRPC UI server.

  ## Options

  - `:name` - GenServer name (optional, defaults to `__MODULE__`)
  - `:timeout` - Response timeout in milliseconds (default: 30_000)
  - `:output_device` - IO device for writing output (default: :stdio)
  """
  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Stops the DebugRPC UI server.
  """
  def stop(server \\ __MODULE__) do
    GenServer.stop(server)
  end

  @doc """
  Routes a ui_response from the debug script to this adapter.

  The debug script calls this when it receives a `{"type": "ui_response", ...}` message.
  """
  def handle_response(server \\ __MODULE__, response) when is_map(response) do
    GenServer.cast(server, {:ui_response, response})
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

  @doc """
  Send a notification to the client.

  Accepts an optional `:server` option for testing.
  """
  def notify(message, type, opts) when is_list(opts) do
    server = get_server(opts)
    GenServer.cast(server, {:signal, "ui_notify", %{message: message, notify_type: type}})
    :ok
  end

  @impl CodingAgent.UI
  def notify(message, type) do
    notify(message, type, [])
  end

  @impl CodingAgent.UI
  def set_status(key, text) do
    server = get_server([])
    GenServer.cast(server, {:signal, "ui_status", %{key: key, text: text}})
    :ok
  end

  @impl CodingAgent.UI
  def set_widget(key, content, opts \\ []) do
    {server, widget_opts} = extract_server(opts)
    cleaned = clean_opts(widget_opts)
    GenServer.cast(server, {:signal, "ui_widget", %{key: key, content: content, opts: cleaned}})
    :ok
  end

  @impl CodingAgent.UI
  def set_working_message(message) do
    server = get_server([])
    GenServer.cast(server, {:signal, "ui_working", %{message: message}})
    :ok
  end

  @impl CodingAgent.UI
  def set_title(title) do
    server = get_server([])
    GenServer.cast(server, {:signal, "ui_set_title", %{title: title}})
    :ok
  end

  @impl CodingAgent.UI
  def set_editor_text(text) do
    server = get_server([])
    GenServer.cast(server, {:signal, "ui_set_editor_text", %{text: text}})
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
    output_device = Keyword.get(opts, :output_device, :stdio)

    state = %{
      pending_requests: %{},
      timeout: timeout,
      output_device: output_device,
      editor_text: ""
    }

    {:ok, state}
  end

  @impl GenServer
  def handle_call({:request, method, params}, from, state) do
    request_id = UUID.uuid4()

    request = %{
      type: "ui_request",
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
  def handle_cast({:signal, type, params}, state) do
    signal = %{
      type: type,
      params: params
    }

    send_json(state.output_device, signal)

    # Track editor_text locally for get_editor_text
    state =
      if type == "ui_set_editor_text" do
        %{state | editor_text: params.text || ""}
      else
        state
      end

    {:noreply, state}
  end

  @impl GenServer
  def handle_cast({:ui_response, response}, state) do
    case response do
      %{"id" => id} ->
        handle_response_internal(id, response, state)

      _ ->
        Logger.warning("[DebugRPC UI] Received response without id: #{inspect(response)}")
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
  def terminate(_reason, state) do
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

  # Extract :server from opts and return {server, remaining_opts}
  defp extract_server(opts) do
    {Keyword.get(opts, :server, __MODULE__), Keyword.delete(opts, :server)}
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

  defp handle_response_internal(id, response, state) do
    case Map.pop(state.pending_requests, id) do
      {{from, timer_ref}, pending} ->
        # Cancel timeout timer
        Process.cancel_timer(timer_ref)

        # Send reply
        result = parse_response(response)
        GenServer.reply(from, result)

        {:noreply, %{state | pending_requests: pending}}

      {nil, _} ->
        Logger.warning("[DebugRPC UI] Received response for unknown request: #{id}")
        {:noreply, state}
    end
  end

  # Error takes precedence over result to avoid masking failures
  defp parse_response(%{"error" => error}) when not is_nil(error) do
    {:error, error}
  end

  defp parse_response(%{"result" => result, "error" => nil}) do
    {:ok, result}
  end

  defp parse_response(%{"result" => result}) when not is_nil(result) do
    {:ok, result}
  end

  defp parse_response(%{"result" => nil, "error" => nil}) do
    # Canceled - return nil result
    {:ok, nil}
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
