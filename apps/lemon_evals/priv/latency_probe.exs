# Loaded only in the benchmark's disposable VM, never in a user's runtime.
defmodule LemonEvals.LatencyProbe do
  alias CodingAgent.ExecutionNode.Socket

  def now, do: System.monotonic_time(:microsecond)

  def request(conn) do
    unless conn.host == "api.z.ai" and
             conn.request_path == "/api/coding/paas/v4/chat/completions",
           do: raise("offline latency probe rejected provider route")

    {:ok, body, conn} = Plug.Conn.read_body(conn)

    unless Jason.decode!(body)["model"] == "glm-5.3",
      do: raise("offline latency probe rejected model switch")

    send(Process.whereis(__MODULE__), {:provider_request, self(), now()})

    receive do
      :release -> :ok
    after
      30_000 -> raise "latency provider barrier timed out"
    end

    # Reuse the existing AI protocol fixture, including its usage-only chunk.
    sse = File.read!(System.fetch_env!("LEMON_LATENCY_SSE"))
    send(Process.whereis(__MODULE__), {:provider_token, now()})
    Plug.Conn.send_resp(conn, 200, sse)
  end

  def stage([:coding_agent, :session, :start_stage], measurements, metadata, owner) do
    send(
      owner,
      {:stage, metadata.stage,
       System.convert_time_unit(measurements.duration, :native, :microsecond)}
    )
  end

  def stage([:lemon, :run, boundary], _measurements, metadata, owner) do
    send(owner, {:boundary, {boundary, metadata.run_id}, now()})
  end

  defp boundary(marks, key) do
    Map.get(marks, key) ||
      receive do
        {:boundary, ^key, at} -> at
      after
        30_000 -> raise "latency gateway boundary missing"
      end
  end

  def run do
    Process.register(self(), __MODULE__)
    Req.default_options(plug: &__MODULE__.request/1)
    Application.put_env(:tzdata, :autoupdate, :disabled)
    File.cd!(System.fetch_env!("LEMON_AGENT_PROFILES_CWD"))
    LemonEvals.PairedCleanup.configure!()
    Application.put_env(:lemon_control_plane, :ip, {127, 0, 0, 1})

    for app <- [:lemon_gateway, :lemon_router] do
      Application.put_env(app, :health_ip, :loopback)
      Application.put_env(app, :health_port, 0)
    end

    boot = now()
    LemonCore.Runtime.Boot.start!(:runtime_full)
    LemonEvals.PairedCleanup.verify!()

    :ok =
      :telemetry.attach_many(
        "latency-start-stages",
        [
          [:coding_agent, :session, :start_stage],
          [:lemon, :run, :start],
          [:lemon, :run, :first_token],
          [:lemon, :run, :stop]
        ],
        &__MODULE__.stage/4,
        self()
      )

    {:ok, socket} =
      Socket.start_link(
        owner: self(),
        url: "ws://127.0.0.1:#{System.fetch_env!("LEMON_CONTROL_PLANE_PORT")}/ws",
        ping_interval_ms: 0,
        connect_params: %{
          "role" => "operator",
          "auth" => %{"token" => System.fetch_env!("LEMON_CONTROL_PLANE_OPERATOR_TOKEN")},
          "client" => %{"id" => "offline-latency"}
        }
      )

    receive do
      {:execution_node_socket, ^socket, {:connected, _}} -> :ok
    after
      30_000 -> raise "latency control-plane handshake failed"
    end

    boot_us = now() - boot
    warm = now()

    cold_ready_us =
      System.system_time(:microsecond) -
        String.to_integer(System.fetch_env!("LEMON_LATENCY_LAUNCHED_US"))

    Socket.request(socket, "health", %{}, :health)
    response(socket, :health)
    warm_us = now() - warm

    rows =
      for n <- 1..String.to_integer(System.fetch_env!("LEMON_LATENCY_TURNS")),
          do: trial(socket, n)

    :telemetry.detach("latency-start-stages")

    File.write!(
      System.fetch_env!("LEMON_LATENCY_RESULT"),
      Jason.encode!(%{
        boot_to_ready: [boot_us],
        warm_ready: [warm_us],
        trials: rows,
        cold_ready_us: cold_ready_us,
        elixir: System.version(),
        otp: to_string(:erlang.system_info(:otp_release))
      })
    )
  end

  defp response(socket, tag) do
    receive do
      {:execution_node_socket, ^socket, {:response, ^tag, {:ok, value}}} ->
        value

      {:execution_node_socket, ^socket, {:response, ^tag, {:error, _}}} ->
        raise "latency control-plane request failed"
    after
      30_000 -> raise "latency control-plane response timed out"
    end
  end

  defp trial(socket, n) do
    params = %{
      "prompt" => "Reply with the fixture text.",
      "model" => "zai:glm-5.3",
      "sessionKey" => "agent:default:latency-#{n}",
      "queueMode" => "followup",
      "cwd" => File.cwd!(),
      "project_memory_capture" => false
    }

    enter = now()
    Socket.request(socket, "agent", params, :first)
    first = response(socket, :first)["runId"]

    {provider, requested} =
      receive do
        {:provider_request, pid, at} -> {pid, at}
      after
        30_000 -> raise "latency provider request timed out"
      end

    LemonControlPlane.EventBridge.subscribe_run(first)
    :sys.get_state(LemonControlPlane.EventBridge)
    # Admission of the second turn is acknowledged before the first can finish.
    Socket.request(socket, "agent", params, :second)
    second = response(socket, :second)["runId"]

    unless is_binary(first) and first != "" and is_binary(second) and second != "" and
             first != second,
           do: raise("latency queue did not acquire two runs")

    LemonControlPlane.EventBridge.subscribe_run(second)
    :sys.get_state(LemonControlPlane.EventBridge)
    send(provider, :release)
    collect(socket, first, second, %{enter_to_provider: requested - enter}, %{}, 0)
  end

  defp collect(socket, first, second, row, marks, completed) do
    receive do
      {:boundary, key, at} ->
        collect(socket, first, second, row, Map.put(marks, key, at), completed)

      {:stage, stage, duration} ->
        key = "session_#{stage}"
        row = Map.update(row, key, [duration], &[duration | &1])
        collect(socket, first, second, row, marks, completed)

      {:provider_request, pid, at} ->
        send(pid, :release)
        collect(socket, first, second, row, Map.put(marks, :next_request, at), completed)

      {:provider_token, at} ->
        collect(socket, first, second, row, Map.put_new(marks, :token, at), completed)

      {:execution_node_socket, ^socket, {:event, "chat", %{"type" => "delta"} = data}} ->
        if data["runId"] == first and data["text"] not in [nil, ""] and
             not Map.has_key?(row, :provider_to_client) do
          received = now()

          token =
            Map.get(marks, :token) ||
              receive do
                {:provider_token, at} -> at
              after
                30_000 -> raise "latency token timestamp missing"
              end

          gateway_token = boundary(marks, {:first_token, first})

          row =
            row
            |> Map.put(:provider_to_gateway_token, gateway_token - token)
            |> Map.put(:gateway_token_to_client, received - gateway_token)
            |> Map.put(:provider_to_client, received - token)

          collect(socket, first, second, row, marks, completed)
        else
          collect(socket, first, second, row, marks, completed)
        end

      {:execution_node_socket, ^socket, {:event, "agent", %{"type" => "started"}}} ->
        collect(socket, first, second, row, marks, completed)

      {:execution_node_socket, ^socket, {:event, "agent", %{"type" => "completed"} = data}} ->
        unless data["ok"], do: raise("latency fixture run failed")

        if completed == 1 do
          row =
            Map.put(
              row,
              :completion_to_next_start,
              boundary(marks, {:start, second}) - boundary(marks, {:stop, first})
            )

          unless Map.has_key?(row, :provider_to_client), do: raise("latency delta missing")
          row
        else
          collect(socket, first, second, row, marks, completed + 1)
        end

      _ ->
        collect(socket, first, second, row, marks, completed)
    after
      30_000 -> raise "latency trial timed out (missing lifecycle or delta event)"
    end
  end
end

LemonEvals.LatencyProbe.run()
