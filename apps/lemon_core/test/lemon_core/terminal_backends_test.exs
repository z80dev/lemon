defmodule LemonCore.TerminalBackendsTest do
  use ExUnit.Case, async: true

  alias LemonCore.TerminalBackends

  describe "list/0" do
    test "exposes the local backend metadata" do
      assert [local, local_pty, docker, ssh] = TerminalBackends.list()

      assert local.id == :local
      assert local.label == "Local shell"
      assert local.available == true
      assert local.isolation == :host
      assert local.pty == false
      assert local.supervised == true
      assert local.transport == :erlang_port
      assert local.policy.allowed == true
      assert local.policy.requires_approval == false
      assert local.capabilities == [:shell, :stdin, :logs, :kill, :exit_status, :cwd, :env]

      assert local_pty.id == :local_pty
      assert local_pty.label == "Local PTY shell"
      assert local_pty.isolation == :host
      assert local_pty.pty == true
      assert local_pty.supervised == true
      assert local_pty.transport == :util_linux_script
      assert :pty in local_pty.capabilities

      assert docker.id == :docker
      assert docker.label == "Docker container shell"
      assert docker.isolation == :container
      assert docker.pty == false
      assert docker.supervised == true
      assert docker.transport == :docker_cli
      assert docker.image == "alpine:3.20"
      assert docker.network == "none"
      assert docker.memory == "1g"
      assert docker.cpus == "2"
      assert docker.pids_limit == "256"
      assert docker.read_only_rootfs == true
      assert docker.tmpfs == ["/tmp:rw,noexec,nosuid,nodev,size=64m"]
      assert docker.workspace_mount == :cwd
      assert docker.pull_policy == :never
      assert docker.drops_capabilities == true
      assert docker.no_new_privileges == true
      assert docker.policy.allowed == true
      assert docker.policy.docker.pull_policy == :never
      assert :container in docker.capabilities
      assert :resource_limits in docker.capabilities

      assert ssh.id == :ssh
      assert ssh.label == "SSH shell"
      assert ssh.isolation == :remote_host
      assert ssh.pty == false
      assert ssh.supervised == true
      assert ssh.transport == :openssh_cli
      assert ssh.configured == System.get_env("LEMON_SSH_TERMINAL_TARGET") not in [nil, ""]

      assert ssh.identity_file_configured ==
               System.get_env("LEMON_SSH_TERMINAL_IDENTITY_FILE") not in [nil, ""]

      assert ssh.user_known_hosts_file_configured ==
               System.get_env("LEMON_SSH_TERMINAL_USER_KNOWN_HOSTS_FILE") not in [nil, ""]

      assert ssh.port == System.get_env("LEMON_SSH_TERMINAL_PORT", "22")
      assert ssh.batch_mode == true
      assert ssh.policy.ssh.allowed_targets_configured == false

      assert ssh.strict_host_key_checking ==
               System.get_env("LEMON_SSH_TERMINAL_STRICT_HOST_KEY_CHECKING", "yes")

      assert :remote in ssh.capabilities
      assert :ssh in ssh.capabilities
    end
  end

  describe "validate/1" do
    test "normalizes the local backend id" do
      assert TerminalBackends.validate(nil) == {:ok, :local}
      assert TerminalBackends.validate(:local) == {:ok, :local}
      assert TerminalBackends.validate("local") == {:ok, :local}
      assert TerminalBackends.validate("LOCAL") == {:ok, :local}
      assert TerminalBackends.validate(" local ") == {:ok, :local}
      assert TerminalBackends.validate("local-pty") == {:ok, :local_pty}
      assert TerminalBackends.validate("LOCAL_PTY") == {:ok, :local_pty}
      assert TerminalBackends.validate("docker") == {:ok, :docker}
      assert TerminalBackends.validate("DOCKER") == {:ok, :docker}
      assert TerminalBackends.validate("ssh") == {:ok, :ssh}
      assert TerminalBackends.validate("SSH") == {:ok, :ssh}
    end

    test "rejects unknown backends without creating atoms" do
      assert TerminalBackends.validate("unknown-docker") == {:error, :unknown_backend}
    end
  end

  describe "capabilities/1" do
    test "returns capabilities for known backends" do
      capabilities = TerminalBackends.capabilities(:local)

      assert :shell in capabilities
      assert :stdin in capabilities
      assert :exit_status in capabilities

      pty_capabilities = TerminalBackends.capabilities(:local_pty)

      assert :pty in pty_capabilities
    end

    test "returns an empty list for unknown backends" do
      assert TerminalBackends.capabilities("unknown-docker") == []
    end
  end

  describe "available?/1" do
    test "reports host availability" do
      assert TerminalBackends.available?(:local) == true
      assert TerminalBackends.available?(:local_pty) == (System.find_executable("script") != nil)
      assert TerminalBackends.available?(:docker) == (System.find_executable("docker") != nil)

      ssh_configured? = System.get_env("LEMON_SSH_TERMINAL_TARGET") not in [nil, ""]

      assert TerminalBackends.available?(:ssh) ==
               (System.find_executable("ssh") != nil and ssh_configured?)
    end
  end

  describe "diagnostics/0" do
    test "returns redacted support metadata" do
      diagnostics = TerminalBackends.diagnostics()

      assert diagnostics.count == 4
      assert diagnostics.default_backend == :local
      assert diagnostics.policy.backend_allowlist_configured == false
      assert :local in diagnostics.policy.allowed_backends
      assert diagnostics.policy.approval_required_backends == []
      assert [local, local_pty, docker, ssh] = diagnostics.backends
      assert local.id == :local
      assert local_pty.id == :local_pty
      assert docker.id == :docker
      assert ssh.id == :ssh
      assert diagnostics.cleanup.includes_commands == false
      assert diagnostics.cleanup.includes_environment == false
      assert diagnostics.cleanup.includes_process_output == false
    end
  end
end
