defmodule LemonCore.TerminalBackends.Local do
  @moduledoc """
  Local host shell backend.
  """

  @behaviour LemonCore.TerminalBackend

  @impl true
  def id, do: :local

  @impl true
  def label, do: "Local shell"

  @impl true
  def available?, do: true

  @impl true
  def capabilities do
    [:shell, :stdin, :logs, :kill, :exit_status, :cwd, :env]
  end

  @impl true
  def metadata do
    %{
      isolation: :host,
      pty: false,
      supervised: true,
      transport: :erlang_port
    }
  end
end
