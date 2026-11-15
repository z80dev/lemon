defmodule LemonCore.TerminalBackends.Docker do
  @moduledoc """
  Docker container shell backend.
  """

  @behaviour LemonCore.TerminalBackend

  @default_image "alpine:3.20"
  @default_memory "1g"
  @default_cpus "2"
  @default_pids_limit "256"
  @default_tmpfs_size "64m"

  @impl true
  def id, do: :docker

  @impl true
  def label, do: "Docker container shell"

  @impl true
  def available? do
    docker_path() != nil
  end

  @impl true
  def capabilities do
    [
      :shell,
      :stdin,
      :logs,
      :kill,
      :exit_status,
      :cwd,
      :env,
      :container,
      :filesystem_mount,
      :resource_limits
    ]
  end

  @impl true
  def metadata do
    %{
      isolation: :container,
      pty: false,
      supervised: true,
      transport: :docker_cli,
      executable: docker_path(),
      image: image(),
      network: network(),
      memory: memory(),
      cpus: cpus(),
      pids_limit: pids_limit(),
      read_only_rootfs: read_only_rootfs?(),
      tmpfs: tmpfs_mounts(),
      workspace_mount: :cwd,
      pull_policy: :never,
      drops_capabilities: true,
      no_new_privileges: true
    }
  end

  def image, do: env("LEMON_DOCKER_TERMINAL_IMAGE", @default_image)
  def memory, do: env("LEMON_DOCKER_TERMINAL_MEMORY", @default_memory)
  def cpus, do: env("LEMON_DOCKER_TERMINAL_CPUS", @default_cpus)
  def pids_limit, do: env("LEMON_DOCKER_TERMINAL_PIDS_LIMIT", @default_pids_limit)
  def network, do: env("LEMON_DOCKER_TERMINAL_NETWORK", "none")
  def tmpfs_size, do: env("LEMON_DOCKER_TERMINAL_TMPFS_SIZE", @default_tmpfs_size)
  def docker_path, do: System.find_executable("docker")

  def read_only_rootfs? do
    case System.get_env("LEMON_DOCKER_TERMINAL_READ_ONLY_ROOTFS") do
      value when value in [nil, ""] -> true
      value -> String.downcase(String.trim(value)) not in ["0", "false", "no", "off"]
    end
  end

  def tmpfs_mounts do
    if read_only_rootfs?() do
      ["/tmp:rw,noexec,nosuid,nodev,size=#{tmpfs_size()}"]
    else
      []
    end
  end

  @doc """
  Builds Docker argv without executing Docker. A broker descriptor forces
  network isolation, read-only rootfs, and the public broker-only mount.
  It contains no credential values or CA private keys.
  """
  def args(command, cwd, env, broker \\ nil) do
    workspace = Path.expand(if cwd in [nil, ""], do: File.cwd!(), else: cwd)
    sandbox? = is_map(broker)
    read_only? = sandbox? or read_only_rootfs?()

    base = [
      "run",
      "--rm",
      "-i",
      "--pull",
      "never",
      "--network",
      if(sandbox?, do: "none", else: network()),
      "--memory",
      memory(),
      "--cpus",
      cpus(),
      "--pids-limit",
      pids_limit(),
      "--cap-drop",
      "ALL",
      "--security-opt",
      "no-new-privileges",
      "--workdir",
      "/workspace",
      "--volume",
      "#{workspace}:/workspace"
    ]

    isolation =
      if read_only? do
        ["--read-only", "--tmpfs", "/tmp:rw,noexec,nosuid,nodev,size=#{tmpfs_size()}"]
      else
        []
      end

    {mounts, env, entrypoint} =
      if sandbox? do
        env =
          Map.merge(env, %{
            "HTTPS_PROXY" => "http://127.0.0.1:18080",
            "https_proxy" => "http://127.0.0.1:18080",
            "NO_PROXY" => "",
            "no_proxy" => "",
            "SSL_CERT_FILE" => "/tmp/lemon-egress-ca.pem"
          })

        {[
           "--user",
           "#{broker.uid}:#{broker.gid}",
           "--volume",
           "#{broker.directory}:/run/lemon-egress:ro"
         ], env, ["python3", "-I", "/run/lemon-egress/adapter.py", command]}
      else
        {[], env, ["/bin/sh", "-lc", command]}
      end

    invocation =
      if sandbox?,
        do: ["--entrypoint", hd(entrypoint), image() | tl(entrypoint)],
        else: [image() | entrypoint]

    base ++
      isolation ++
      mounts ++
      Enum.flat_map(Enum.sort(env), fn {key, value} -> ["--env", "#{key}=#{value}"] end) ++
      invocation
  end

  defp env(name, default) do
    case System.get_env(name) do
      nil -> default
      "" -> default
      value -> value
    end
  end
end
