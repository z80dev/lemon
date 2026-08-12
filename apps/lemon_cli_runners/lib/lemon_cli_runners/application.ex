defmodule LemonCliRunners.Application do
  @moduledoc """
  Contributes this package's vendor CLIs to the platform's subagent registry.

  There is no supervision tree here — the runners are started per run by their
  caller. The application callback exists for one reason: the platform must not
  name vendors, so each vendor package announces itself at boot instead of
  appearing in a list somewhere in `coding_agent` or in `config/config.exs`.

  Registration order is the order engines appear in the `task` tool's
  description, so it is the order a reader should meet them in.

  A runtime without `:lemon_core` — or one where its registry has not started —
  simply has no CLI subagents; `register/1` answers `{:error, :unavailable}`
  and boot continues.
  """

  use Application

  require Logger

  @subagents [
    LemonCliRunners.CodexSubagent,
    LemonCliRunners.ClaudeSubagent,
    LemonCliRunners.KimiSubagent,
    LemonCliRunners.OpencodeSubagent,
    LemonCliRunners.PiSubagent
  ]

  @doc "The subagent runners this package registers at boot."
  @spec subagents() :: [module()]
  def subagents, do: @subagents

  @impl true
  def start(_type, _args) do
    case Supervisor.start_link([], strategy: :one_for_one, name: LemonCliRunners.Supervisor) do
      {:ok, _supervisor} = ok ->
        register_subagents()
        ok

      other ->
        other
    end
  end

  defp register_subagents do
    Enum.each(@subagents, fn module ->
      case LemonCore.SubagentRegistry.register(module) do
        :ok ->
          :ok

        {:error, reason} ->
          Logger.debug("subagent #{inspect(module)} not registered: #{inspect(reason)}")
          :ok
      end
    end)
  end
end
