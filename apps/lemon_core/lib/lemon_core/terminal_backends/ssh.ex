defmodule LemonCore.TerminalBackends.Ssh do
  @moduledoc """
  SSH remote shell backend backed by OpenSSH.
  """

  @behaviour LemonCore.TerminalBackend

  @impl true
  def id, do: :ssh

  @impl true
  def label, do: "SSH shell"

  @impl true
  def available? do
    ssh_path() != nil and target() != nil
  end

  @impl true
  def capabilities do
    [:shell, :stdin, :logs, :kill, :exit_status, :env, :remote, :ssh]
  end

  @impl true
  def metadata do
    %{
      isolation: :remote_host,
      pty: false,
      supervised: true,
      transport: :openssh_cli,
      executable: ssh_path(),
      configured: target() != nil,
      identity_file_configured: identity_file() != nil,
      user_known_hosts_file_configured: user_known_hosts_file() != nil,
      target_hash: target_hash(),
      port: port(),
      batch_mode: true,
      connect_timeout_seconds: connect_timeout_seconds(),
      strict_host_key_checking: strict_host_key_checking(),
      remote_workdir_configured: remote_workdir() != nil
    }
  end

  def ssh_path, do: System.find_executable("ssh")
  def target, do: env("LEMON_SSH_TERMINAL_TARGET")
  def identity_file, do: env("LEMON_SSH_TERMINAL_IDENTITY_FILE")
  def user_known_hosts_file, do: env("LEMON_SSH_TERMINAL_USER_KNOWN_HOSTS_FILE")
  def remote_workdir, do: env("LEMON_SSH_TERMINAL_WORKDIR")
  def port, do: env("LEMON_SSH_TERMINAL_PORT") || "22"
  def connect_timeout_seconds, do: env("LEMON_SSH_TERMINAL_CONNECT_TIMEOUT") || "10"
  def strict_host_key_checking, do: env("LEMON_SSH_TERMINAL_STRICT_HOST_KEY_CHECKING") || "yes"

  def args(command, env) do
    []
    |> add_arg("-o", "BatchMode=yes")
    |> add_arg("-o", "ConnectTimeout=#{connect_timeout_seconds()}")
    |> add_arg("-o", "StrictHostKeyChecking=#{strict_host_key_checking()}")
    |> add_optional_arg("-o", user_known_hosts_file(), &"UserKnownHostsFile=#{&1}")
    |> add_optional_arg("-i", identity_file())
    |> add_arg("-p", port())
    |> Kernel.++([target(), remote_command(command, Map.new(env))])
  end

  defp add_arg(args, key, value), do: args ++ [key, value]
  defp add_optional_arg(args, _key, nil), do: args
  defp add_optional_arg(args, key, value), do: args ++ [key, value]
  defp add_optional_arg(args, _key, nil, _fun), do: args
  defp add_optional_arg(args, key, value, fun), do: args ++ [key, fun.(value)]

  defp remote_command(command, env) do
    command
    |> with_env(env)
    |> with_workdir(remote_workdir())
  end

  defp with_env(command, env) when map_size(env) == 0, do: command

  defp with_env(command, env) do
    prefix =
      env
      |> Enum.map(fn {key, value} -> "#{key}=#{shell_escape(value)}" end)
      |> Enum.join(" ")

    "#{prefix} #{command}"
  end

  defp with_workdir(command, nil), do: command
  defp with_workdir(command, workdir), do: "cd #{shell_escape(workdir)} && #{command}"

  defp target_hash do
    case target() do
      nil ->
        nil

      value ->
        :crypto.hash(:sha256, value)
        |> Base.encode16(case: :lower)
        |> binary_part(0, 16)
    end
  end

  defp env(name) do
    case System.get_env(name) do
      nil -> nil
      "" -> nil
      value -> value
    end
  end

  defp shell_escape(value) do
    "'" <> String.replace(to_string(value), "'", "'\"'\"'") <> "'"
  end
end
