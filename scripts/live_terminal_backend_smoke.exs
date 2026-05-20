Application.ensure_all_started(:coding_agent)

defmodule LemonTerminalBackendSmoke do
  alias CodingAgent.ProcessManager
  alias LemonCore.TerminalBackends

  def run do
    with_loopback_ssh(fn loopback ->
      output_path =
        System.get_env("LEMON_TERMINAL_SMOKE_RESULT_PATH") ||
          Path.join(["tmp", "terminal-backend-smoke.json"])

      File.mkdir_p!(Path.dirname(output_path))

      cwd = File.cwd!()
      backends = TerminalBackends.list()

      results =
        backends
        |> Enum.map(fn backend ->
          id = backend.id

          cond do
            backend.available != true ->
              skipped(id, "backend unavailable")

            id == :docker and not docker_ready?() ->
              skipped(id, "docker daemon or configured image unavailable")

            true ->
              run_backend(id, command_for_backend(id), cwd)
          end
        end)

      summary = %{
        generated_at: DateTime.utc_now() |> DateTime.to_iso8601(),
        command_hash: hash("lemon-terminal-backend-smoke-v2"),
        command_hashes:
          Map.new(backends, fn backend -> {backend.id, hash(command_for_backend(backend.id))} end),
        cwd_hash: hash(cwd),
        loopback_ssh: loopback,
        results: results,
        completed_count: Enum.count(results, &(&1.status == "completed")),
        skipped_count: Enum.count(results, &(&1.status == "skipped")),
        failed_count: Enum.count(results, &(&1.status == "failed"))
      }

      File.write!(output_path, Jason.encode!(summary, pretty: true))
      IO.puts("terminal backend smoke wrote #{output_path}")

      IO.puts(
        "completed=#{summary.completed_count} skipped=#{summary.skipped_count} failed=#{summary.failed_count}"
      )

      if summary.failed_count > 0 do
        System.halt(1)
      end
    end)
  end

  defp run_backend(id, command, cwd) do
    case ProcessManager.exec_sync(
           command: command,
           backend: id,
           cwd: cwd,
           timeout_ms: 15_000,
           use_lane_queue: false
         ) do
      {:ok, %{status: :completed, logs: logs, exit_code: 0} = result} ->
        text = Enum.join(logs, "\n")

        if Enum.all?(expected_markers(id), &String.contains?(text, &1)) do
          completed(id, result)
        else
          failed(id, {:missing_expected_output, result.exit_code})
        end

      {:ok, result} ->
        failed(id, {:unexpected_result, Map.take(result, [:status, :exit_code])})

      {:error, reason} ->
        failed(id, reason)
    end
  rescue
    error ->
      failed(id, Exception.message(error))
  end

  defp command_for_backend(:docker) do
    memory_bytes = docker_memory_bytes()
    cpu_quota = docker_cpu_quota()
    pids_limit = LemonCore.TerminalBackends.Docker.pids_limit()

    """
    printf lemon-terminal-smoke
    if touch /lemon-root-write-probe 2>/dev/null; then exit 41; fi
    if [ "$(awk '/NoNewPrivs:/ {print $2}' /proc/self/status)" != "1" ]; then exit 42; fi
    if [ "$(awk '/CapEff:/ {print $2}' /proc/self/status)" != "0000000000000000" ]; then exit 43; fi
    printf '#!/bin/sh\\nexit 13\\n' > /tmp/lemon-noexec-probe
    chmod +x /tmp/lemon-noexec-probe
    if /tmp/lemon-noexec-probe >/dev/null 2>&1; then exit 44; fi
    if ! grep -E ' /tmp .*noexec' /proc/mounts >/dev/null 2>&1; then exit 45; fi
    if [ -r /sys/fs/cgroup/memory.max ]; then
      if [ "$(cat /sys/fs/cgroup/memory.max)" != "#{memory_bytes}" ]; then exit 46; fi
    elif [ -r /sys/fs/cgroup/memory/memory.limit_in_bytes ]; then
      if [ "$(cat /sys/fs/cgroup/memory/memory.limit_in_bytes)" != "#{memory_bytes}" ]; then exit 46; fi
    fi
    if [ -r /sys/fs/cgroup/cpu.max ]; then
      if [ "$(cat /sys/fs/cgroup/cpu.max)" != "#{cpu_quota} 100000" ]; then exit 47; fi
    fi
    if [ -r /sys/fs/cgroup/pids.max ]; then
      if [ "$(cat /sys/fs/cgroup/pids.max)" != "#{pids_limit}" ]; then exit 48; fi
    elif [ -r /sys/fs/cgroup/pids/pids.max ]; then
      if [ "$(cat /sys/fs/cgroup/pids/pids.max)" != "#{pids_limit}" ]; then exit 48; fi
    fi
    printf ' lemon-docker-hardening lemon-docker-cgroups'
    """
  end

  defp command_for_backend(_id), do: "printf lemon-terminal-smoke"

  defp expected_markers(:docker),
    do: ["lemon-terminal-smoke", "lemon-docker-hardening", "lemon-docker-cgroups"]

  defp expected_markers(_id), do: ["lemon-terminal-smoke"]

  defp completed(:docker = id, result) do
    completed(id, result, %{
      hardening: %{
        read_only_rootfs: true,
        tmpfs_noexec: true,
        drops_capabilities: true,
        no_new_privileges: true,
        cgroup_memory_limit: true,
        cgroup_cpu_quota: true,
        cgroup_pids_limit: true,
        pull_policy: "never",
        network: LemonCore.TerminalBackends.Docker.network(),
        memory: LemonCore.TerminalBackends.Docker.memory(),
        cpus: LemonCore.TerminalBackends.Docker.cpus(),
        pids_limit: LemonCore.TerminalBackends.Docker.pids_limit()
      }
    })
  end

  defp completed(id, result) do
    completed(id, result, %{})
  end

  defp completed(id, result, extra) do
    %{
      backend: id,
      status: "completed",
      exit_code: result.exit_code,
      output_hash: hash(Enum.join(result.logs, "\n"))
    }
    |> Map.merge(extra)
  end

  defp docker_memory_bytes do
    size_to_bytes(LemonCore.TerminalBackends.Docker.memory()) || "1073741824"
  end

  defp docker_cpu_quota do
    cpus = LemonCore.TerminalBackends.Docker.cpus()

    case Float.parse(cpus) do
      {value, ""} when value > 0 ->
        value
        |> Kernel.*(100_000)
        |> round()
        |> to_string()

      _ ->
        "200000"
    end
  end

  defp size_to_bytes(value) do
    normalized = value |> to_string() |> String.trim() |> String.downcase()

    with [_, number, suffix] <- Regex.run(~r/^([1-9][0-9]*)([kmg])?b?$/, normalized),
         {integer, ""} <- Integer.parse(number) do
      multiplier =
        case suffix do
          "k" -> 1024
          "m" -> 1024 * 1024
          "g" -> 1024 * 1024 * 1024
          _ -> 1
        end

      to_string(integer * multiplier)
    else
      _ -> nil
    end
  end

  defp skipped(id, reason) do
    %{
      backend: id,
      status: "skipped",
      reason: reason
    }
  end

  defp failed(id, reason) do
    %{
      backend: id,
      status: "failed",
      reason: inspect(reason)
    }
  end

  defp docker_ready? do
    docker = LemonCore.TerminalBackends.Docker.docker_path()

    docker != nil and
      cmd_ok?(docker, ["version", "--format", "{{.Server.Version}}"]) and
      cmd_ok?(docker, ["image", "inspect", LemonCore.TerminalBackends.Docker.image()])
  end

  defp cmd_ok?(executable, args) do
    task = Task.async(fn -> System.cmd(executable, args, stderr_to_stdout: true) end)

    case Task.yield(task, 5_000) || Task.shutdown(task, :brutal_kill) do
      {:ok, {_, 0}} -> true
      _ -> false
    end
  rescue
    _ -> false
  end

  defp with_loopback_ssh(fun) do
    case start_loopback_ssh() do
      {:ok, loopback, cleanup} ->
        try do
          fun.(loopback)
        after
          cleanup.()
        end

      {:skip, reason} ->
        fun.(%{started: false, reason: reason})
    end
  end

  defp start_loopback_ssh do
    cond do
      configured_ssh_target?() ->
        {:skip, "LEMON_SSH_TERMINAL_TARGET already configured"}

      disabled_loopback_ssh?() ->
        {:skip, "loopback SSH disabled by LEMON_TERMINAL_SMOKE_LOOPBACK_SSH"}

      true ->
        do_start_loopback_ssh()
    end
  end

  defp do_start_loopback_ssh do
    with {:ok, sshd} <- executable("sshd"),
         {:ok, ssh_keygen} <- executable("ssh-keygen"),
         {:ok, tmp_dir} <- make_tmp_dir(),
         {:ok, client_key} <- generate_key(ssh_keygen, tmp_dir, "client_key"),
         {:ok, host_key} <- generate_key(ssh_keygen, tmp_dir, "host_key"),
         {:ok, authorized_keys} <- authorized_keys(tmp_dir, client_key),
         {:ok, port} <- free_port(),
         {:ok, config} <- sshd_config(tmp_dir, host_key, authorized_keys, port),
         {:ok, port_ref} <- start_sshd(sshd, config, tmp_dir) do
      target = "#{System.get_env("USER") || username()}@127.0.0.1"
      known_hosts = Path.join(tmp_dir, "known_hosts")
      previous_env = set_loopback_env(target, port, client_key, known_hosts)

      case wait_for_ssh(port, target, client_key, known_hosts) do
        :ok ->
          loopback = %{
            started: true,
            target_hash: hash(target),
            port: port,
            identity_file_configured: true,
            user_known_hosts_file_configured: true,
            strict_host_key_checking: "accept-new"
          }

          cleanup = fn ->
            restore_env(previous_env)
            stop_port(port_ref)
            File.rm_rf(tmp_dir)
          end

          {:ok, loopback, cleanup}

        {:error, reason} ->
          stop_port(port_ref)
          File.rm_rf(tmp_dir)
          {:skip, "loopback SSH unavailable: #{inspect(reason)}"}
      end
    else
      {:error, reason} -> {:skip, "loopback SSH unavailable: #{inspect(reason)}"}
    end
  end

  defp executable(name) do
    case System.find_executable(name) do
      nil -> {:error, {:missing_executable, name}}
      path -> {:ok, path}
    end
  end

  defp make_tmp_dir do
    dir = Path.join(System.tmp_dir!(), "lemon-terminal-ssh-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    {:ok, dir}
  end

  defp generate_key(ssh_keygen, tmp_dir, name) do
    path = Path.join(tmp_dir, name)

    case System.cmd(ssh_keygen, ["-q", "-t", "ed25519", "-N", "", "-f", path],
           stderr_to_stdout: true
         ) do
      {_output, 0} -> {:ok, path}
      {output, code} -> {:error, {:ssh_keygen_failed, name, code, output}}
    end
  end

  defp authorized_keys(tmp_dir, client_key) do
    path = Path.join(tmp_dir, "authorized_keys")
    File.cp!(client_key <> ".pub", path)
    {:ok, path}
  end

  defp free_port do
    {:ok, socket} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
    {:ok, port} = :inet.port(socket)
    :gen_tcp.close(socket)
    {:ok, port}
  rescue
    error -> {:error, error}
  end

  defp sshd_config(tmp_dir, host_key, authorized_keys, port) do
    path = Path.join(tmp_dir, "sshd_config")

    File.write!(path, """
    HostKey #{host_key}
    PidFile #{Path.join(tmp_dir, "sshd.pid")}
    AuthorizedKeysFile #{authorized_keys}
    PasswordAuthentication no
    PubkeyAuthentication yes
    KbdInteractiveAuthentication no
    ChallengeResponseAuthentication no
    UsePAM no
    PermitRootLogin no
    StrictModes no
    ListenAddress 127.0.0.1
    Port #{port}
    LogLevel ERROR
    PrintMotd no
    Subsystem sftp internal-sftp
    """)

    {:ok, path}
  end

  defp start_sshd(sshd, config, tmp_dir) do
    port =
      Port.open({:spawn_executable, sshd}, [
        :binary,
        :exit_status,
        args: ["-D", "-f", config, "-E", Path.join(tmp_dir, "sshd.log")]
      ])

    {:ok, port}
  rescue
    error -> {:error, error}
  end

  defp wait_for_ssh(port, target, client_key, known_hosts) do
    args = [
      "-i",
      client_key,
      "-o",
      "BatchMode=yes",
      "-o",
      "ConnectTimeout=1",
      "-o",
      "StrictHostKeyChecking=accept-new",
      "-o",
      "UserKnownHostsFile=#{known_hosts}",
      "-p",
      to_string(port),
      target,
      "true"
    ]

    1..20
    |> Enum.reduce_while({:error, :not_ready}, fn _attempt, _last ->
      case System.cmd("ssh", args, stderr_to_stdout: true) do
        {_output, 0} ->
          {:halt, :ok}

        {output, code} ->
          Process.sleep(100)
          {:cont, {:error, {:ssh_probe_failed, code, output}}}
      end
    end)
  end

  defp set_loopback_env(target, port, client_key, known_hosts) do
    env = %{
      "LEMON_SSH_TERMINAL_TARGET" => target,
      "LEMON_SSH_TERMINAL_PORT" => to_string(port),
      "LEMON_SSH_TERMINAL_IDENTITY_FILE" => client_key,
      "LEMON_SSH_TERMINAL_USER_KNOWN_HOSTS_FILE" => known_hosts,
      "LEMON_SSH_TERMINAL_STRICT_HOST_KEY_CHECKING" => "accept-new",
      "LEMON_SSH_TERMINAL_CONNECT_TIMEOUT" => "3",
      "LEMON_SSH_TERMINAL_ALLOWED_TARGETS" => target
    }

    previous = Map.new(Map.keys(env), &{&1, System.get_env(&1)})
    Enum.each(env, fn {key, value} -> System.put_env(key, value) end)
    previous
  end

  defp restore_env(previous) do
    Enum.each(previous, fn
      {key, nil} -> System.delete_env(key)
      {key, value} -> System.put_env(key, value)
    end)
  end

  defp stop_port(port) do
    Port.close(port)
  rescue
    _ -> :ok
  end

  defp configured_ssh_target? do
    System.get_env("LEMON_SSH_TERMINAL_TARGET") not in [nil, ""]
  end

  defp disabled_loopback_ssh? do
    value = System.get_env("LEMON_TERMINAL_SMOKE_LOOPBACK_SSH")
    value in ["0", "false", "FALSE", "no", "NO"]
  end

  defp username do
    case System.cmd("whoami", [], stderr_to_stdout: true) do
      {name, 0} -> String.trim(name)
      _ -> "unknown"
    end
  end

  defp hash(value) do
    :crypto.hash(:sha256, to_string(value))
    |> Base.encode16(case: :lower)
    |> binary_part(0, 16)
  end
end

LemonTerminalBackendSmoke.run()
