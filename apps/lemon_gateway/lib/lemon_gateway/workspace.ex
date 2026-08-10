defmodule LemonGateway.Workspace do
  @moduledoc """
  Where gateway tools write files they hand back to a channel.

  The value is configured rather than read from the agent product, so the
  gateway does not depend on it:

      config :lemon_gateway, :workspace_dir, "/srv/lemon/workspace"

  An `{module, function, args}` tuple is also accepted, which is how the
  reference runtime forwards coding_agent's own workspace directory:

      config :lemon_gateway, :workspace_dir, {CodingAgent.Config, :workspace_dir, []}

  With nothing configured — or a configured module that is not loaded — it
  falls back to `$LEMON_AGENT_DIR/workspace`, defaulting to
  `~/.lemon/agent/workspace`, which is the layout the agent uses.
  """

  @default_agent_dir_segments [".lemon", "agent"]

  @doc "Absolute path of the workspace directory."
  @spec dir() :: String.t()
  def dir do
    case Application.get_env(:lemon_gateway, :workspace_dir) do
      path when is_binary(path) and path != "" ->
        Path.expand(path)

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
        path when is_binary(path) and path != "" -> Path.expand(path)
        _ -> default_dir()
      end
    else
      default_dir()
    end
  end

  defp default_dir do
    agent_dir =
      System.get_env("LEMON_AGENT_DIR") ||
        Path.join([System.user_home() || "~" | @default_agent_dir_segments])

    agent_dir |> Path.join("workspace") |> Path.expand()
  end
end
