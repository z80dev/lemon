defmodule LemonControlPlane.ACP.Connection do
  @moduledoc """
  Duplex ACP transport inside the existing runtime.

  Each connection owns its request workers and client-request correlations.
  Disconnect cancels active turns but retains durable sessions for later resume.
  """
  @behaviour WebSock

  alias LemonControlPlane.ACP

  @impl true
  def init(opts) do
    {:ok,
     %{
       workers: %{},
       clients: %{},
       terminals: %{},
       capabilities: nil,
       scopes: Keyword.get(opts, :scopes, []),
       principal: Keyword.get(opts, :principal)
     }}
  end

  @impl true
  def handle_in({encoded, [opcode: :text]}, state) do
    case Jason.decode(encoded) do
      {:ok, %{"id" => id} = response}
      when not is_map_key(response, "method") and
             (is_map_key(response, "result") or is_map_key(response, "error")) ->
        case Map.pop(state.clients, id) do
          {nil, _clients} ->
            {:ok, state}

          {client, clients} ->
            Process.demonitor(client.monitor, [:flush])
            state = record_terminal_response(%{state | clients: clients}, client, response)

            unless client.cancelled,
              do: send(client.pid, {:acp_client_response, client.ref, {:ok, response}})

            {:ok, state}
        end

      {:ok, %{"method" => "$/cancel_request", "params" => %{"requestId" => id}}} ->
        session =
          Enum.find_value(state.workers, fn {_ref, worker} ->
            if worker.id == id and worker.method == "session/prompt", do: worker.session
          end)

        {:ok, cancel_session(state, session)}

      {:ok, request} ->
        state = remember_capabilities(state, request)
        state = maybe_cancel_clients(state, request)
        {:ok, start_request(state, request)}

      {:error, _reason} ->
        {:push, {:text, Jason.encode!(error(nil, -32_700, "parse error"))}, state}
    end
  end

  def handle_in(_frame, state), do: {:ok, state}

  @impl true
  def handle_info({:acp_output, message}, state) do
    {:push, {:text, Jason.encode!(message)}, state}
  end

  def handle_info({:acp_client_request, pid, ref, request, session, worker}, state) do
    id = "lemon_req_#{System.unique_integer([:positive])}"

    client = %{
      pid: pid,
      ref: ref,
      session: session,
      worker: worker,
      monitor: Process.monitor(pid),
      cancelled: false,
      method: request["method"],
      terminal_id: get_in(request, ["params", "terminalId"])
    }

    clients = Map.put(state.clients, id, client)
    {:push, {:text, Jason.encode!(Map.put(request, "id", id))}, %{state | clients: clients}}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    case Map.pop(state.workers, ref) do
      {nil, _workers} ->
        {:ok, cancel_clients(state, fn client -> client.monitor == ref end)}

      {worker, workers} ->
        state = %{state | workers: workers}
        state = cleanup_terminals(state, fn terminal -> terminal.worker == worker.pid end)
        state = cancel_clients(state, fn client -> client.worker == worker.pid end)

        if reason != :normal and not is_nil(worker.id) do
          {:push, {:text, Jason.encode!(error(worker.id, -32_603, "ACP request failed"))}, state}
        else
          {:ok, state}
        end
    end
  end

  def handle_info(_message, state), do: {:ok, state}

  @impl true
  def terminate(_reason, state) do
    state.workers
    |> Map.values()
    |> Enum.filter(&(&1.method == "session/prompt"))
    |> Enum.each(fn worker -> cancel_turn(worker.session) end)

    Enum.each(state.clients, fn {_id, client} ->
      send(client.pid, {:acp_client_response, client.ref, {:error, :cancelled}})
    end)

    Enum.each(state.workers, fn {_ref, worker} -> Process.exit(worker.pid, :shutdown) end)
    :ok
  end

  defp start_request(state, request) do
    owner = self()
    capabilities = state.capabilities
    scopes = state.scopes
    principal = state.principal
    method = if is_map(request), do: request["method"]
    params = if is_map(request), do: request["params"] || %{}, else: %{}
    session = if is_map(params), do: params["sessionId"]
    buffered? = method in ["session/new", "session/resume", "session/fork"]

    {pid, ref} =
      spawn_monitor(fn ->
        Process.put(:acp_bootstrap, [])
        worker = self()

        opts = [
          client_capabilities: capabilities,
          scopes: scopes,
          principal: principal,
          connection_pid: owner,
          session_update_callback: fn message ->
            if buffered? do
              Process.put(:acp_bootstrap, [message | Process.get(:acp_bootstrap)])
            else
              send(owner, {:acp_output, message})
            end
          end,
          client_request_callback: fn message ->
            correlation = make_ref()
            monitor = Process.monitor(owner)
            send(owner, {:acp_client_request, self(), correlation, message, session, worker})

            timeout =
              if message["method"] in ["terminal/wait_for_exit", "session/request_permission"],
                do: :infinity,
                else: 60_000

            try do
              receive do
                {:acp_client_response, ^correlation, result} -> result
                {:DOWN, ^monitor, :process, ^owner, _} -> {:error, :disconnected}
              after
                timeout -> {:error, :timeout}
              end
            after
              Process.demonitor(monitor, [:flush])
            end
          end
        ]

        case ACP.handle_jsonrpc(request, opts) do
          {:ok, :noreply} -> :ok
          :noreply -> :ok
          {:ok, response} -> send(owner, {:acp_output, response})
        end

        Process.get(:acp_bootstrap)
        |> Enum.reverse()
        |> Enum.each(&send(owner, {:acp_output, &1}))
      end)

    worker = %{
      pid: pid,
      id: if(is_map(request), do: request["id"]),
      method: method,
      session: session
    }

    %{state | workers: Map.put(state.workers, ref, worker)}
  end

  defp remember_capabilities(state, %{"method" => "initialize", "params" => params})
       when is_map(params) do
    %{state | capabilities: ACP.normalize_client_capabilities(params["clientCapabilities"])}
  end

  defp remember_capabilities(state, _request), do: state

  defp maybe_cancel_clients(state, %{
         "method" => "session/cancel",
         "params" => %{"sessionId" => session}
       }),
       do: release_clients(state, session)

  defp maybe_cancel_clients(state, _request), do: state

  defp cancel_session(state, nil), do: state

  defp cancel_session(state, session) do
    cancel_turn(session)
    release_clients(state, session)
  end

  defp cancel_turn(nil), do: :ok

  defp cancel_turn(session) do
    ACP.handle_jsonrpc(%{
      "jsonrpc" => "2.0",
      "method" => "session/cancel",
      "params" => %{"sessionId" => session}
    })
  end

  defp release_clients(state, session) do
    state
    |> cleanup_terminals(fn terminal -> terminal.session == session end)
    |> cancel_clients(fn client -> client.session == session end)
  end

  defp cancel_clients(state, matches?) do
    clients =
      Enum.reduce(state.clients, %{}, fn {id, client}, acc ->
        if matches?.(client) do
          Process.demonitor(client.monitor, [:flush])

          unless client.cancelled do
            send(client.pid, {:acp_client_response, client.ref, {:error, :cancelled}})

            send(
              self(),
              {:acp_output,
               %{
                 "jsonrpc" => "2.0",
                 "method" => "$/cancel_request",
                 "params" => %{"requestId" => id}
               }}
            )
          end

          # Allocation cannot be undone until the client supplies its terminal ID.
          # Retain cancelled creates so their eventual response is killed/released.
          if client.method == "terminal/create",
            do: Map.put(acc, id, %{client | cancelled: true}),
            else: acc
        else
          Map.put(acc, id, client)
        end
      end)

    %{state | clients: clients}
  end

  defp record_terminal_response(state, %{method: "terminal/create"} = client, response) do
    case get_in(response, ["result", "terminalId"]) do
      id when is_binary(id) and id != "" ->
        if client.cancelled do
          release_terminal(client.session, id)
          state
        else
          terminal = %{session: client.session, worker: client.worker}
          %{state | terminals: Map.put(state.terminals, id, terminal)}
        end

      _ ->
        state
    end
  end

  defp record_terminal_response(state, %{method: "terminal/release", terminal_id: id}, %{
         "result" => _
       }),
       do: %{state | terminals: Map.delete(state.terminals, id)}

  defp record_terminal_response(state, _client, _response), do: state

  defp cleanup_terminals(state, matches?) do
    terminals =
      Enum.reduce(state.terminals, %{}, fn {id, terminal}, acc ->
        if matches?.(terminal) do
          release_terminal(terminal.session, id)
          acc
        else
          Map.put(acc, id, terminal)
        end
      end)

    %{state | terminals: terminals}
  end

  defp release_terminal(session, id) do
    for method <- ["terminal/kill", "terminal/release"] do
      send(
        self(),
        {:acp_output,
         %{
           "jsonrpc" => "2.0",
           "id" => "lemon_cleanup_#{System.unique_integer([:positive])}",
           "method" => method,
           "params" => %{"sessionId" => session, "terminalId" => id}
         }}
      )
    end
  end

  defp error(id, code, message),
    do: %{"jsonrpc" => "2.0", "id" => id, "error" => %{"code" => code, "message" => message}}
end
