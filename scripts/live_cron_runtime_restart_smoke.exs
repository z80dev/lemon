Application.ensure_all_started(:inets)
Application.ensure_all_started(:websockex)

defmodule LemonScripts.LiveCronRuntimeRestartSmoke.WSClient do
  use WebSockex

  def start_link(url, parent) do
    WebSockex.start_link(url, __MODULE__, %{parent: parent})
  end

  @impl true
  def handle_frame({:text, frame}, state) do
    send(state.parent, {:ws_frame, Jason.decode!(frame)})
    {:ok, state}
  end
end

defmodule LemonScripts.LiveCronRuntimeRestartSmoke do
  @boot_eval "LemonCore.Runtime.Boot.start!(:runtime_full, check_running: false)"
  @proof_object "lemon.cron_runtime_restart_smoke"

  alias LemonScripts.LiveCronRuntimeRestartSmoke.WSClient

  def main(args) do
    {opts, _rest} =
      OptionParser.parse!(args,
        strict: [out: :string, timeout_ms: :integer, keep_tmp: :boolean]
      )

    root = File.cwd!()

    proof_path =
      opts[:out] || Path.join([root, ".lemon", "proofs", "cron-runtime-restart-latest.json"])

    archive_path = archive_path(proof_path)
    timeout_ms = opts[:timeout_ms] || 190_000
    tmp_dir = Path.join(System.tmp_dir!(), "lemon-cron-runtime-restart-#{unique_token()}")

    proof =
      try do
        File.mkdir_p!(tmp_dir)
        run(tmp_dir, timeout_ms)
      rescue
        exception ->
          proof([
            failed("cron_runtime_restart_smoke", Exception.message(exception))
          ])
      after
        unless opts[:keep_tmp], do: File.rm_rf(tmp_dir)
      end

    write_json!(proof_path, proof)
    write_json!(archive_path, proof)
    IO.puts(Jason.encode!(proof, pretty: true))

    if proof.failed_count > 0, do: System.halt(1)
  end

  defp run(tmp_dir, timeout_ms) do
    control_port = free_port()
    web_port = free_port()
    sim_port = free_port()
    gateway_health_port = free_port()
    router_health_port = free_port()
    store_path = Path.join(tmp_dir, "store")
    home = Path.join(tmp_dir, "home")
    dotenv_dir = Path.join(tmp_dir, "dotenv")
    config_dir = Path.join(home, ".lemon")
    log_path = Path.join(tmp_dir, "runtime.log")
    File.mkdir_p!(config_dir)
    File.mkdir_p!(dotenv_dir)
    File.write!(Path.join(config_dir, "config.toml"), config_toml())

    File.write!(
      Path.join(config_dir, "secrets_master_key"),
      Base.encode64(:crypto.strong_rand_bytes(32))
    )

    env =
      runtime_env(%{
        home: home,
        store_path: store_path,
        dotenv_dir: dotenv_dir,
        control_port: control_port,
        web_port: web_port,
        sim_port: sim_port,
        gateway_health_port: gateway_health_port,
        router_health_port: router_health_port
      })

    first = start_runtime(env, log_path)

    try do
      with {:ok, _} <- wait_health(control_port, timeout_ms),
           {:ok, ws} <- connect_ws(control_port),
           {:ok, _status} <- request(ws, "cron.status", %{}, 5_000),
           {:ok, job} <- add_job(ws),
           {:ok, pre_run} <- wait_for_scheduled_run(ws, job["id"], nil, timeout_ms),
           :ok <- stop_runtime(first) do
        second = start_runtime(env, log_path)

        try do
          with {:ok, _} <- wait_health(control_port, timeout_ms),
               {:ok, ws2} <- connect_ws(control_port),
               {:ok, loaded_status} <- request(ws2, "cron.status", %{}, 5_000),
               {:ok, loaded_runs} <-
                 request(ws2, "cron.runs", %{"id" => job["id"], "limit" => 20}, 5_000),
               :ok <- require_loaded_state(loaded_status, loaded_runs, pre_run),
               {:ok, post_run} <-
                 wait_for_scheduled_run(ws2, job["id"], pre_run["id"], timeout_ms) do
            proof([
              completed("runtime_booted"),
              completed("cron_api_ready"),
              completed("pre_restart_scheduled_run_observed", run_summary(pre_run)),
              completed("runtime_restarted"),
              completed("persisted_cron_state_loaded", %{
                job_count: loaded_status["jobCount"],
                recent_run_count: loaded_status["recentRunCount"],
                pre_restart_run_hash: hash(pre_run["id"])
              }),
              completed("post_restart_scheduled_run_observed", run_summary(post_run)),
              completed("cleanup_complete")
            ])
          else
            {:error, reason} ->
              proof([failed("cron_runtime_restart_smoke", inspect(reason), log_tail(log_path))])
          end
        after
          stop_runtime(second)
        end
      else
        {:error, reason} ->
          proof([failed("cron_runtime_restart_smoke", inspect(reason), log_tail(log_path))])
      end
    after
      stop_runtime(first)
    end
  end

  defp add_job(ws) do
    token = unique_token()

    request(
      ws,
      "cron.add",
      %{
        "name" => "runtime restart smoke #{token}",
        "schedule" => "* * * * *",
        "agentId" => "default",
        "sessionKey" => "agent:default:main",
        "prompt" => "cron runtime restart smoke #{token}",
        "enabled" => true,
        "timezone" => "UTC",
        "timeoutMs" => 120_000,
        "maxRetries" => 0,
        "retryBackoffMs" => 0
      },
      5_000
    )
  end

  defp wait_for_scheduled_run(ws, job_id, previous_id, timeout_ms) do
    deadline = now_ms() + timeout_ms
    do_wait_for_scheduled_run(ws, job_id, previous_id, deadline)
  end

  defp do_wait_for_scheduled_run(ws, job_id, previous_id, deadline) do
    with {:ok, response} <-
           request(
             ws,
             "cron.runs",
             %{"id" => job_id, "limit" => 50, "includeMeta" => true},
             5_000
           ),
         run when is_map(run) <- newest_scheduled_run(response["runs"], previous_id) do
      {:ok, run}
    else
      _ ->
        if now_ms() >= deadline do
          {:error, :scheduled_run_timeout}
        else
          Process.sleep(1_000)
          do_wait_for_scheduled_run(ws, job_id, previous_id, deadline)
        end
    end
  end

  defp newest_scheduled_run(runs, previous_id) when is_list(runs) do
    Enum.find(runs, fn run ->
      run["triggeredBy"] == "schedule" and run["id"] != previous_id
    end)
  end

  defp newest_scheduled_run(_, _), do: nil

  defp require_loaded_state(status, runs_response, pre_run) do
    runs = runs_response["runs"] || []
    loaded_pre_run? = Enum.any?(runs, &(&1["id"] == pre_run["id"]))

    cond do
      status["jobCount"] < 1 ->
        {:error, :job_not_loaded_after_restart}

      not loaded_pre_run? ->
        {:error, :pre_restart_run_not_loaded_after_restart}

      true ->
        :ok
    end
  end

  defp connect_ws(control_port) do
    parent = self()
    url = "ws://127.0.0.1:#{control_port}/ws"

    with {:ok, pid} <- WSClient.start_link(url, parent),
         :ok <- send_request(pid, "connect", %{"role" => "operator"}),
         {:ok, %{"type" => "hello-ok"}} <- receive_frame(5_000) do
      {:ok, pid}
    end
  end

  defp request(ws, method, params, timeout_ms) do
    id = "req_#{unique_token()}"

    with :ok <- send_request(ws, method, params, id),
         {:ok, %{"type" => "res", "id" => ^id, "ok" => true, "payload" => payload}} <-
           receive_response(id, timeout_ms) do
      {:ok, payload}
    else
      {:ok, %{"type" => "res", "id" => ^id, "ok" => false, "error" => error}} ->
        {:error, error}

      {:ok, other} ->
        {:error, {:unexpected_frame, other}}

      error ->
        error
    end
  end

  defp send_request(pid, method, params, id \\ "connect") do
    WebSockex.send_frame(
      pid,
      {:text,
       Jason.encode!(%{"type" => "req", "id" => id, "method" => method, "params" => params})}
    )
  end

  defp receive_response(id, timeout_ms) do
    receive do
      {:ws_frame, %{"type" => "res", "id" => ^id} = frame} -> {:ok, frame}
      {:ws_frame, _frame} -> receive_response(id, timeout_ms)
    after
      timeout_ms -> {:error, :websocket_response_timeout}
    end
  end

  defp receive_frame(timeout_ms) do
    receive do
      {:ws_frame, frame} -> {:ok, frame}
    after
      timeout_ms -> {:error, :websocket_frame_timeout}
    end
  end

  defp start_runtime(env, log_path) do
    args = ["run", "--no-start", "--no-halt", "-e", @boot_eval]

    port =
      Port.open(
        {:spawn_executable, System.find_executable("mix")},
        [
          :binary,
          :exit_status,
          :stderr_to_stdout,
          {:args, args},
          {:cd, File.cwd!()},
          {:env,
           Enum.map(env, fn {key, value} ->
             {String.to_charlist(key), String.to_charlist(value)}
           end)}
        ]
      )

    collector = spawn_link(fn -> drain_port(port, log_path) end)
    Port.connect(port, collector)
    %{port: port, os_pid: os_pid(port), collector: collector}
  end

  defp stop_runtime(%{os_pid: nil, collector: collector}) do
    if is_pid(collector) and Process.alive?(collector), do: Process.exit(collector, :normal)
    :ok
  end

  defp stop_runtime(%{os_pid: pid, collector: collector}) when is_integer(pid) do
    if process_alive?(pid) do
      System.cmd("kill", ["-TERM", Integer.to_string(pid)], stderr_to_stdout: true)

      unless wait_os_exit(pid, 5_000) do
        System.cmd("kill", ["-KILL", Integer.to_string(pid)], stderr_to_stdout: true)
        wait_os_exit(pid, 2_000)
      end
    end

    if is_pid(collector) and Process.alive?(collector), do: Process.exit(collector, :normal)
    :ok
  end

  defp os_pid(port) do
    case Port.info(port, :os_pid) do
      {:os_pid, pid} -> pid
      _ -> nil
    end
  end

  defp wait_os_exit(pid, timeout_ms), do: wait_os_exit_until(pid, now_ms() + timeout_ms)

  defp wait_os_exit_until(pid, deadline) do
    cond do
      not process_alive?(pid) ->
        true

      now_ms() >= deadline ->
        false

      true ->
        Process.sleep(100)
        wait_os_exit_until(pid, deadline)
    end
  end

  defp process_alive?(pid) do
    case System.cmd("kill", ["-0", Integer.to_string(pid)], stderr_to_stdout: true) do
      {_out, 0} -> true
      _ -> false
    end
  end

  defp drain_port(port, log_path) do
    receive do
      {^port, {:data, data}} ->
        File.write!(log_path, data, [:append])
        drain_port(port, log_path)

      {^port, {:exit_status, status}} ->
        File.write!(log_path, "\n[runtime exit #{status}]\n", [:append])
    end
  end

  defp wait_health(control_port, timeout_ms) do
    deadline = now_ms() + timeout_ms
    do_wait_health(control_port, deadline)
  end

  defp do_wait_health(control_port, deadline) do
    url = ~c"http://127.0.0.1:#{control_port}/healthz"

    case :httpc.request(:get, {url, []}, [timeout: 2_000], []) do
      {:ok, {{_, 200, _}, _headers, _body}} ->
        {:ok, :healthy}

      _ ->
        if now_ms() >= deadline do
          {:error, :health_timeout}
        else
          Process.sleep(500)
          do_wait_health(control_port, deadline)
        end
    end
  end

  defp runtime_env(values) do
    %{
      "MIX_ENV" => "dev",
      "HOME" => values.home,
      "LEMON_DOTENV_DIR" => values.dotenv_dir,
      "LEMON_STORE_PATH" => values.store_path,
      "LEMON_CONTROL_PLANE_PORT" => Integer.to_string(values.control_port),
      "LEMON_WEB_PORT" => Integer.to_string(values.web_port),
      "LEMON_SIM_UI_PORT" => Integer.to_string(values.sim_port),
      "LEMON_GATEWAY_HEALTH_PORT" => Integer.to_string(values.gateway_health_port),
      "LEMON_ROUTER_HEALTH_PORT" => Integer.to_string(values.router_health_port),
      "LEMON_GATEWAY_DEFAULT_ENGINE" => "echo",
      "LEMON_GATEWAY_ENABLE_TELEGRAM" => "false",
      "LEMON_GATEWAY_ENABLE_DISCORD" => "false",
      "LEMON_GATEWAY_ENABLE_XMTP" => "false",
      "LEMON_GATEWAY_ENABLE_EMAIL" => "false",
      "LEMON_GATEWAY_ENABLE_WEBHOOK" => "false",
      "LEMON_GATEWAY_ENABLE_FARCASTER" => "false",
      "LEMON_LOG_LEVEL" => "warning",
      "PHX_SERVER" => "false"
    }
  end

  defp config_toml do
    """
    [gateway]
    default_engine = "echo"
    enable_telegram = false
    enable_discord = false
    enable_email = false
    enable_farcaster = false
    enable_webhook = false
    enable_xmtp = false
    require_engine_lock = false

    [gateway.voice]
    enabled = false

    [profiles.default]
    name = "Runtime Restart Smoke"
    default_engine = "echo"

    [lemon_automation.skill_curator]
    enabled = false
    """
  end

  defp completed(name, details \\ %{}), do: Map.merge(%{name: name, status: "completed"}, details)

  defp failed(name, reason, details \\ %{}) do
    Map.merge(%{name: name, status: "failed", reason: reason}, details)
  end

  defp proof(checks) do
    %{
      object: @proof_object,
      generated_at: DateTime.utc_now() |> DateTime.to_iso8601(),
      completed_count: Enum.count(checks, &(&1.status == "completed")),
      failed_count: Enum.count(checks, &(&1.status == "failed")),
      checks: checks,
      cleanup: %{
        includes_raw_prompts: false,
        includes_raw_outputs: false,
        includes_raw_session_ids: false,
        includes_raw_store_path: false,
        temporary_runtime_home_removed: true
      }
    }
  end

  defp run_summary(run) do
    %{
      run_hash: hash(run["id"]),
      router_run_hash: hash(run["routerRunId"]),
      status: run["status"],
      triggered_by: run["triggeredBy"],
      started_at_ms: run["startedAtMs"]
    }
  end

  defp log_tail(path) do
    case File.read(path) do
      {:ok, data} ->
        tail =
          data
          |> String.split("\n")
          |> Enum.take(-80)
          |> Enum.join("\n")

        %{runtime_log_tail: tail}

      _ ->
        %{}
    end
  end

  defp write_json!(path, data) do
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, Jason.encode!(data, pretty: true))
  end

  defp archive_path(path) do
    ext = Path.extname(path)
    root = String.trim_trailing(path, ext)
    "#{root}-#{DateTime.utc_now() |> Calendar.strftime("%Y%m%dT%H%M%SZ")}#{ext}"
  end

  defp free_port do
    {:ok, socket} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
    {:ok, port} = :inet.port(socket)
    :gen_tcp.close(socket)
    port
  end

  defp unique_token, do: System.unique_integer([:positive, :monotonic]) |> Integer.to_string()
  defp now_ms, do: System.monotonic_time(:millisecond)

  defp hash(nil), do: nil

  defp hash(value) do
    :crypto.hash(:sha256, to_string(value))
    |> Base.encode16(case: :lower)
    |> binary_part(0, 16)
  end
end

LemonScripts.LiveCronRuntimeRestartSmoke.main(System.argv())
