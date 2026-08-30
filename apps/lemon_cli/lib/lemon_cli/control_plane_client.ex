defmodule LemonCli.ControlPlaneClient do
  @moduledoc """
  Small synchronous JSON-RPC client for one-shot packaged CLI commands.

  Release CLI commands execute in a fresh non-booted VM. Commands that must
  affect the long-running runtime therefore connect to its authenticated local
  control plane instead of starting a second router or submitting work that
  disappears when the CLI VM exits.
  """

  use WebSockex

  @default_timeout_ms 5_000

  @spec request(String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def request(method, params, opts \\ []) when is_binary(method) and is_map(params) do
    timeout_ms = Keyword.get(opts, :timeout_ms, @default_timeout_ms)
    url = Keyword.get(opts, :url) || default_url()
    ref = make_ref()

    with {:ok, _started} <- Application.ensure_all_started(:websockex),
         {:ok, pid} <- WebSockex.start(url, __MODULE__, %{owner: self(), ref: ref}) do
      try do
        with :ok <- send_connect(pid, token(opts)),
             :ok <- receive_hello(ref, timeout_ms),
             request_id = request_id(),
             :ok <- send_request(pid, request_id, method, params),
             {:ok, frame} <- receive_response(ref, request_id, timeout_ms) do
          case frame do
            %{"ok" => true, "payload" => payload} when is_map(payload) -> {:ok, payload}
            %{"ok" => false, "error" => error} -> {:error, {:control_plane, error}}
            other -> {:error, {:unexpected_response, other}}
          end
        end
      after
        if Process.alive?(pid), do: WebSockex.cast(pid, :close)
      end
    else
      {:error, reason} -> {:error, {:control_plane_unavailable, reason}}
    end
  end

  @impl true
  def handle_frame({:text, encoded}, state) do
    frame =
      case Jason.decode(encoded) do
        {:ok, decoded} -> decoded
        {:error, reason} -> {:invalid_json, reason}
      end

    send(state.owner, {:lemon_cli_control_plane, state.ref, frame})
    {:ok, state}
  end

  @impl true
  def handle_disconnect(disconnect, state) do
    send(state.owner, {:lemon_cli_control_plane, state.ref, {:disconnected, disconnect}})
    {:ok, state}
  end

  @impl true
  def handle_cast(:close, state), do: {:close, state}

  defp send_connect(pid, token) do
    params =
      %{"role" => "operator", "client" => %{"name" => "lemon-cli", "version" => "1"}}
      |> maybe_put_auth(token)

    send_frame(pid, %{
      "type" => "req",
      "id" => "connect",
      "method" => "connect",
      "params" => params
    })
  end

  defp send_request(pid, id, method, params) do
    send_frame(pid, %{"type" => "req", "id" => id, "method" => method, "params" => params})
  end

  defp send_frame(pid, frame), do: WebSockex.send_frame(pid, {:text, Jason.encode!(frame)})

  defp receive_frame(ref, timeout_ms) do
    receive do
      {:lemon_cli_control_plane, ^ref, {:disconnected, reason}} ->
        {:error, {:disconnected, reason}}

      {:lemon_cli_control_plane, ^ref, {:invalid_json, reason}} ->
        {:error, {:invalid_json, reason}}

      {:lemon_cli_control_plane, ^ref, frame} ->
        {:ok, frame}
    after
      timeout_ms -> {:error, :control_plane_timeout}
    end
  end

  defp receive_hello(ref, timeout_ms) do
    case receive_frame(ref, timeout_ms) do
      {:ok, %{"type" => "hello-ok"}} ->
        :ok

      {:ok, %{"type" => "res", "ok" => false, "error" => error}} ->
        {:error, {:control_plane, error}}

      {:ok, other} ->
        {:error, {:unexpected_handshake, other}}

      {:error, _reason} = error ->
        error
    end
  end

  defp receive_response(ref, request_id, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_receive_response(ref, request_id, deadline)
  end

  defp do_receive_response(ref, request_id, deadline) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {:lemon_cli_control_plane, ^ref, %{"type" => "res", "id" => ^request_id} = frame} ->
        {:ok, frame}

      {:lemon_cli_control_plane, ^ref, {:disconnected, reason}} ->
        {:error, {:disconnected, reason}}

      {:lemon_cli_control_plane, ^ref, _other} ->
        do_receive_response(ref, request_id, deadline)
    after
      remaining -> {:error, :control_plane_timeout}
    end
  end

  defp default_url do
    port = System.get_env("LEMON_CONTROL_PLANE_PORT") || "4040"
    "ws://127.0.0.1:#{port}/ws"
  end

  defp token(opts) do
    Keyword.get(opts, :token) ||
      System.get_env("LEMON_CONTROL_PLANE_OPERATOR_TOKEN") ||
      System.get_env("LEMON_WS_TOKEN")
  end

  defp maybe_put_auth(params, token) when is_binary(token) and token != "",
    do: Map.put(params, "auth", %{"token" => token})

  defp maybe_put_auth(params, _token), do: params

  defp request_id do
    "cli_" <> (:crypto.strong_rand_bytes(8) |> Base.url_encode64(padding: false))
  end
end
