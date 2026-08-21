defmodule LemonCliRunners.Application do
  @moduledoc """
  Contributes this package's vendor CLIs to the platform's registries.

  There is no supervision tree here — the runners are started per run by their
  caller. The application callback exists for one reason: the platform must not
  name vendors, so each vendor package announces itself at boot instead of
  appearing in a list somewhere in `coding_agent` or in `config/config.exs`.

  Three things are announced per vendor: the subagent runner the `task` tool
  may delegate to, the resume syntax that vendor's CLI speaks
  (`LemonCore.ResumeFormats`), and the resolver for that vendor's
  `[runtime.cli.<engine>]` config section (`LemonCore.Config.CliResolvers`), so
  core does not have to carry a table of per-vendor regexes or defaults.

  Registration order is the order vendors appear in the `task` tool's
  description, so it is the order a reader should meet them in — and, for
  resume formats, the order text is searched in.

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
        register_resume_formats()
        register_cli_resolvers()
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

  # `resume_format/0` is an optional callback, and a format the parser refuses
  # is this package's bug — but neither may take a release down at boot, so the
  # shape here matches `register_subagents/0`: log and carry on with a runner
  # whose resume lines are simply not recognised.
  defp register_resume_formats do
    Enum.each(@subagents, &register_resume_format/1)
  end

  defp register_resume_format(module) do
    if Code.ensure_loaded?(module) and function_exported?(module, :resume_format, 0) do
      LemonCore.ResumeFormats.register(module.resume_format())
    end
  rescue
    error ->
      Logger.error(
        "resume format for #{inspect(module)} not registered: " <> Exception.message(error)
      )
  end

  # `resolve_cli_settings/1` is an optional callback with the same boot
  # posture as `resume_format/0`: a vendor without one simply has its raw
  # config section passed through, and a broken one must not take a release
  # down — log and carry on.
  defp register_cli_resolvers do
    Enum.each(@subagents, &register_cli_resolver/1)
  end

  defp register_cli_resolver(module) do
    if Code.ensure_loaded?(module) and function_exported?(module, :resolve_cli_settings, 1) do
      LemonCore.Config.CliResolvers.register(module.id(), &module.resolve_cli_settings/1)
    end
  rescue
    error ->
      Logger.error(
        "cli resolver for #{inspect(module)} not registered: " <> Exception.message(error)
      )
  end
end
