defmodule LemonCore.TerminalBackends.LocalPty do
  @moduledoc """
  Local host PTY shell backend backed by util-linux script(1).
  """

  @behaviour LemonCore.TerminalBackend

  @impl true
  def id, do: :local_pty

  @impl true
  def label, do: "Local PTY shell"

  @impl true
  def available? do
    match?({:unix, _}, :os.type()) and script_path() != nil
  end

  @impl true
  def capabilities do
    [:shell, :stdin, :logs, :kill, :exit_status, :cwd, :env, :pty]
  end

  @impl true
  def metadata do
    %{
      isolation: :host,
      pty: true,
      supervised: true,
      transport: :util_linux_script,
      executable: script_path()
    }
  end

  defp script_path do
    System.find_executable("script")
  end
end
