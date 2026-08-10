defmodule CodingAgent.Env do
  @moduledoc """
  Environment variables read by `coding_agent` — the coding agent's workspace and session behaviour.

  Aggregated by `LemonCore.Env` through the `:env_registries` list; see
  `LemonCore.Env.Registry`.
  """

  use LemonCore.Env.Registry

  @declarations [
    %{
      name: :lemon_allow_restart_tool,
      env_var: "LEMON_ALLOW_RESTART_TOOL",
      aliases: [],
      type: :boolean,
      default: false,
      doc: "Whether the agent's self-restart tool is permitted to run.",
      secret?: false,
      required?: false,
      area: :runtime,
      apps: [:coding_agent]
    }
  ]
end
