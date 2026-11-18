defmodule LemonCli.AcpCommand do
  @moduledoc """
  ACP stdio client of the authenticated local runtime. This VM starts only
  transport dependencies, never Lemon's router, scheduler or session store.
  A private one-task supervisor owns the blocking stdin reader and is stopped
  when the command exits; this does not start any runtime application.
  """
  use WebSockex

  def run([]) do
    with :ok <- LemonCli.LocalRuntime.ensure_running(),
         {:ok, socket} <- connect(url(), headers()) do
      try do
        run_input(socket)
      after
        if Process.alive?(socket), do: WebSockex.cast(socket, :close)
      end
    else
      {:error, _reason} ->
        IO.puts(
          :stderr,
          "[lemon] Could not attach ACP to the local runtime; check `lemon doctor` and the operator credential."
        )

        1
    end
  end

  def run(_args) do
    IO.puts(:stderr, "usage: lemon acp")
    2
  end

  @doc false
  @spec connect(String.t(), list()) :: {:ok, pid()} | {:error, term()}
  def connect(url, headers) do
    with {:ok, _apps} <- Application.ensure_all_started(:websockex),
         {:ok, url, ws_opts} <- LemonCore.Net.web_socket_options(url, extra_headers: headers) do
      WebSockex.start(url, __MODULE__, %{owner: self()}, ws_opts)
    end
  end

  @impl true
  def handle_frame({:text, encoded}, state) do
    send(state.owner, {:acp_frame, encoded})
    {:ok, state}
  end

  @impl true
  def handle_disconnect(_disconnect, state) do
    send(state.owner, :acp_disconnected)
    {:ok, state}
  end

  @impl true
  def handle_cast(:close, state), do: {:close, state}

  defp run_input(socket) do
    owner = self()
    # Caller policy: exactly one blocking stdin reader per command connection.
    %{start: {module, function, args}} =
      LemonCore.TaskSupervisor.child_spec(max_children: 1)

    case apply(module, function, args) do
      {:ok, supervisor} ->
        try do
          case LemonCore.TaskSupervisor.start_child(supervisor, fn -> read_input(owner) end) do
            {:ok, _reader} -> loop(socket, %{}, false)
            {:error, _reason} -> disconnected()
          end
        after
          Supervisor.stop(supervisor)
        end

      {:error, _reason} ->
        disconnected()
    end
  end

  defp read_input(owner) do
    case IO.read(:stdio, :line) do
      :eof ->
        send(owner, :acp_eof)

      {:error, _reason} ->
        send(owner, :acp_input_error)

      line ->
        unless String.trim(line) == "", do: send(owner, {:acp_input, String.trim(line)})
        read_input(owner)
    end
  end

  defp loop(socket, pending, ending?) do
    receive do
      {:acp_input, encoded} ->
        {encoded, pending} = track_request(encoded, pending)

        case WebSockex.send_frame(socket, {:text, encoded}) do
          :ok -> loop(socket, pending, ending?)
          {:error, _reason} -> disconnected()
        end

      {:acp_frame, encoded} ->
        IO.write(:stdio, encoded <> "\n")
        pending = complete_request(encoded, pending)
        if ending? and map_size(pending) == 0, do: 0, else: loop(socket, pending, ending?)

      :acp_eof ->
        # Drain short requests (for piped initialize/new), but disconnect an
        # active prompt immediately so the runtime cancels its turn.
        if map_size(pending) == 0 or "session/prompt" in Map.values(pending) do
          0
        else
          Process.send_after(self(), :acp_drain_timeout, 5_000)
          loop(socket, pending, true)
        end

      :acp_drain_timeout ->
        0

      :acp_input_error ->
        1

      :acp_disconnected ->
        if ending?, do: 0, else: disconnected()
    end
  end

  defp track_request(encoded, pending) do
    case Jason.decode(encoded) do
      {:ok, %{"id" => id, "method" => method} = request} ->
        request = launch_cwd(request)
        {Jason.encode!(request), Map.put(pending, id, method)}

      _ ->
        {encoded, pending}
    end
  end

  defp complete_request(encoded, pending) do
    case Jason.decode(encoded) do
      {:ok, %{"id" => id} = response} when not is_map_key(response, "method") ->
        Map.delete(pending, id)

      _ ->
        pending
    end
  end

  defp launch_cwd(%{"method" => "session/new"} = request) do
    cwd = System.get_env("LEMON_NODE_LAUNCH_CWD") || File.cwd!()

    Map.update(request, "params", %{"cwd" => cwd}, fn
      params when is_map(params) -> Map.put_new(params, "cwd", cwd)
      other -> other
    end)
  end

  defp launch_cwd(request), do: request

  defp disconnected do
    IO.puts(:stderr, "[lemon] ACP disconnected from the local runtime.")
    1
  end

  defp url do
    port = System.get_env("LEMON_CONTROL_PLANE_PORT") || "4040"
    "ws://127.0.0.1:#{port}/acp/ws"
  end

  defp headers do
    case System.get_env("LEMON_CONTROL_PLANE_OPERATOR_TOKEN") || System.get_env("LEMON_WS_TOKEN") do
      token when is_binary(token) and token != "" -> [{"authorization", "Bearer " <> token}]
      _ -> []
    end
  end
end
