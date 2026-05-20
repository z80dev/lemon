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

  defp env(name, default) do
    case System.get_env(name) do
      nil -> default
      "" -> default
      value -> value
    end
  end
end
