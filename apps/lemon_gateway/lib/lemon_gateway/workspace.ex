defmodule LemonGateway.Workspace do
  @moduledoc """
  Where gateway tools write files they hand back to a channel.

  The value is configured rather than read from the agent product, so the
  gateway does not depend on it:

      config :lemon_gateway, :workspace_dir, "/srv/lemon/workspace"

  An `{module, function, args}` tuple is also accepted, which is how the
  reference runtime forwards coding_agent's own workspace directory:

      config :lemon_gateway, :workspace_dir, {CodingAgent.Config, :workspace_dir, []}

  With nothing configured — or a configured module that is not loaded, or one
  that raises — it falls back to `$LEMON_AGENT_DIR/workspace`, defaulting to
  `~/.lemon/agent/workspace`, which is the layout the agent uses.

  A relative path, from either source, is resolved against the agent directory
  rather than the VM's current working directory. `dir/0` is called from tools
  that write files, long after boot, and `File.cwd!/0` at that point is not a
  location anyone chose.
  """

  require Logger

  @default_agent_dir_segments [".lemon", "agent"]

  @doc "Absolute path of the workspace directory."
  @spec dir() :: String.t()
  def dir do
    case Application.get_env(:lemon_gateway, :workspace_dir) do
      path when is_binary(path) and path != "" ->
        expand(path)

      {module, function, args}
      when is_atom(module) and is_atom(function) and is_list(args) ->
        resolve_mfa(module, function, args)

      _ ->
        default_dir()
    end
  end

  defp resolve_mfa(module, function, args) do
    if Code.ensure_loaded?(module) and function_exported?(module, function, length(args)) do
      case apply(module, function, args) do
        path when is_binary(path) and path != "" -> expand(path)
        _ -> default_dir()
      end
    else
      default_dir()
    end
  rescue
    error ->
      # The configured function belongs to another application; it answering
      # badly should degrade to the default layout, not propagate into whatever
      # tool was about to write a file.
      Logger.warning(
        "workspace_dir MFA #{inspect(module)}.#{function}/#{length(args)} raised, " <>
          "falling back to the default workspace: #{Exception.message(error)}"
      )

      default_dir()
  catch
    kind, reason ->
      Logger.warning(
        "workspace_dir MFA #{inspect(module)}.#{function}/#{length(args)} #{kind} " <>
          "#{inspect(reason)}, falling back to the default workspace"
      )

      default_dir()
  end

  # A relative path here would resolve against whatever the VM's cwd happens to
  # be at call time, which for a long-lived node is not a location anyone chose.
  # Anchor it to the agent directory instead, the same root the default uses.
  defp expand(path) do
    if Path.type(path) == :absolute do
      Path.expand(path)
    else
      Path.expand(path, agent_dir())
    end
  end

  defp default_dir do
    agent_dir() |> Path.join("workspace") |> Path.expand()
  end

  defp agent_dir do
    System.get_env("LEMON_AGENT_DIR") ||
      Path.join([System.user_home() || "~" | @default_agent_dir_segments])
  end
end
