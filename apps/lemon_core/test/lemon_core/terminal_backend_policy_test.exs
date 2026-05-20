defmodule LemonCore.TerminalBackendPolicyTest do
  use ExUnit.Case, async: false

  alias LemonCore.TerminalBackendPolicy

  @env_names [
    "LEMON_TERMINAL_BACKENDS_ALLOW",
    "LEMON_TERMINAL_BACKENDS_DENY",
    "LEMON_TERMINAL_BACKENDS_REQUIRE_APPROVAL",
    "LEMON_DOCKER_TERMINAL_ALLOWED_IMAGES",
    "LEMON_DOCKER_TERMINAL_IMAGE",
    "LEMON_DOCKER_TERMINAL_NETWORK",
    "LEMON_DOCKER_TERMINAL_MEMORY",
    "LEMON_DOCKER_TERMINAL_CPUS",
    "LEMON_DOCKER_TERMINAL_PIDS_LIMIT",
    "LEMON_DOCKER_TERMINAL_READ_ONLY_ROOTFS",
    "LEMON_DOCKER_TERMINAL_TMPFS_SIZE",
    "LEMON_SSH_TERMINAL_ALLOWED_TARGETS",
    "LEMON_SSH_TERMINAL_TARGET",
    "LEMON_SSH_TERMINAL_PORT",
    "LEMON_SSH_TERMINAL_CONNECT_TIMEOUT",
    "LEMON_SSH_TERMINAL_STRICT_HOST_KEY_CHECKING"
  ]

  setup do
    previous = Map.new(@env_names, &{&1, System.get_env(&1)})
    Enum.each(@env_names, &System.delete_env/1)

    on_exit(fn ->
      Enum.each(previous, fn
        {name, nil} -> System.delete_env(name)
        {name, value} -> System.put_env(name, value)
      end)
    end)
  end

  test "allows registered backends by default" do
    assert TerminalBackendPolicy.validate(:local) == :ok
    assert TerminalBackendPolicy.validate(:docker) == :ok
    assert TerminalBackendPolicy.describe(:local).allowed == true
  end

  test "honors backend allowlists and denylists" do
    System.put_env("LEMON_TERMINAL_BACKENDS_ALLOW", "local,docker")

    assert TerminalBackendPolicy.validate(:local) == :ok
    assert TerminalBackendPolicy.validate(:docker) == :ok

    assert TerminalBackendPolicy.validate(:local_pty) ==
             {:error, {:terminal_backend_not_allowed, :local_pty}}

    System.put_env("LEMON_TERMINAL_BACKENDS_DENY", "docker")

    assert TerminalBackendPolicy.validate(:docker) ==
             {:error, {:terminal_backend_denied, :docker}}
  end

  test "reports approval-required backends" do
    System.put_env("LEMON_TERMINAL_BACKENDS_REQUIRE_APPROVAL", "docker,ssh")

    assert TerminalBackendPolicy.requires_approval?(:docker) == true
    assert TerminalBackendPolicy.requires_approval?(:ssh) == true
    assert TerminalBackendPolicy.requires_approval?(:local) == false

    diagnostics = TerminalBackendPolicy.diagnostics()
    assert diagnostics.approval_required_backends == [:docker, :ssh]
    assert TerminalBackendPolicy.describe(:docker).requires_approval == true
  end

  test "constrains docker images when an image allowlist is configured" do
    System.put_env("LEMON_DOCKER_TERMINAL_IMAGE", "alpine:3.20")
    System.put_env("LEMON_DOCKER_TERMINAL_ALLOWED_IMAGES", "alpine:3.20")

    assert TerminalBackendPolicy.validate(:docker) == :ok
    assert TerminalBackendPolicy.describe(:docker).docker.image_allowed == true

    System.put_env("LEMON_DOCKER_TERMINAL_ALLOWED_IMAGES", "debian:stable")

    assert TerminalBackendPolicy.validate(:docker) ==
             {:error, {:docker_image_not_allowed, "alpine:3.20"}}

    assert TerminalBackendPolicy.describe(:docker).docker.image_allowed == false
  end

  test "reports docker filesystem hardening policy" do
    description = TerminalBackendPolicy.describe(:docker)

    assert description.docker.read_only_rootfs == true
    assert description.docker.tmpfs == ["/tmp:rw,noexec,nosuid,nodev,size=64m"]

    System.put_env("LEMON_DOCKER_TERMINAL_READ_ONLY_ROOTFS", "false")

    description = TerminalBackendPolicy.describe(:docker)

    assert description.docker.read_only_rootfs == false
    assert description.docker.tmpfs == []
  end

  test "rejects invalid docker resource policy before launch" do
    System.put_env("LEMON_DOCKER_TERMINAL_IMAGE", "bad image")
    assert TerminalBackendPolicy.validate(:docker) == {:error, :invalid_docker_image}

    System.put_env("LEMON_DOCKER_TERMINAL_IMAGE", "alpine:3.20")
    System.put_env("LEMON_DOCKER_TERMINAL_NETWORK", "bad network")
    assert TerminalBackendPolicy.validate(:docker) == {:error, :invalid_docker_network}

    System.put_env("LEMON_DOCKER_TERMINAL_NETWORK", "none")
    System.put_env("LEMON_DOCKER_TERMINAL_MEMORY", "0m")

    assert TerminalBackendPolicy.validate(:docker) ==
             {:error, {:invalid_docker_resource_limit, "memory"}}

    System.put_env("LEMON_DOCKER_TERMINAL_MEMORY", "512m")
    System.put_env("LEMON_DOCKER_TERMINAL_CPUS", "0")

    assert TerminalBackendPolicy.validate(:docker) ==
             {:error, {:invalid_docker_resource_limit, "cpus"}}

    System.put_env("LEMON_DOCKER_TERMINAL_CPUS", "0.5")
    System.put_env("LEMON_DOCKER_TERMINAL_PIDS_LIMIT", "-1")

    assert TerminalBackendPolicy.validate(:docker) ==
             {:error, {:invalid_terminal_integer, "pids_limit"}}

    System.put_env("LEMON_DOCKER_TERMINAL_PIDS_LIMIT", "64")
    System.put_env("LEMON_DOCKER_TERMINAL_TMPFS_SIZE", "64m")

    assert TerminalBackendPolicy.validate(:docker) == :ok
  end

  test "constrains ssh targets without exposing raw targets" do
    System.put_env("LEMON_SSH_TERMINAL_TARGET", "agent@example.internal")
    System.put_env("LEMON_SSH_TERMINAL_ALLOWED_TARGETS", "agent@example.internal")

    assert TerminalBackendPolicy.validate(:ssh) == :ok
    description = TerminalBackendPolicy.describe(:ssh)

    assert description.ssh.target_allowed == true
    assert is_binary(description.ssh.target_hash)
    refute inspect(description) =~ "agent@example.internal"

    System.put_env("LEMON_SSH_TERMINAL_ALLOWED_TARGETS", "other@example.internal")

    assert TerminalBackendPolicy.validate(:ssh) == {:error, :ssh_target_not_allowed}
    refute inspect(TerminalBackendPolicy.describe(:ssh)) =~ "agent@example.internal"
  end

  test "rejects invalid ssh transport policy before launch" do
    System.put_env("LEMON_SSH_TERMINAL_TARGET", "agent@example.internal")

    System.put_env("LEMON_SSH_TERMINAL_PORT", "70000")
    assert TerminalBackendPolicy.validate(:ssh) == {:error, :invalid_ssh_port}

    System.put_env("LEMON_SSH_TERMINAL_PORT", "22")
    System.put_env("LEMON_SSH_TERMINAL_CONNECT_TIMEOUT", "0")

    assert TerminalBackendPolicy.validate(:ssh) ==
             {:error, {:invalid_terminal_integer, "connect_timeout"}}

    System.put_env("LEMON_SSH_TERMINAL_CONNECT_TIMEOUT", "10")
    System.put_env("LEMON_SSH_TERMINAL_STRICT_HOST_KEY_CHECKING", "maybe")

    assert TerminalBackendPolicy.validate(:ssh) ==
             {:error, :invalid_ssh_strict_host_key_checking}

    System.put_env("LEMON_SSH_TERMINAL_STRICT_HOST_KEY_CHECKING", "accept-new")

    assert TerminalBackendPolicy.validate(:ssh) == :ok
  end
end
