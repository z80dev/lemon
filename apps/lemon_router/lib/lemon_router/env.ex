defmodule LemonRouter.Env do
  @moduledoc """
  Environment variables read by `lemon_router` — run routing and session orchestration.

  Aggregated by `LemonCore.Env` through the `:env_registries` list; see
  `LemonCore.Env.Registry`.
  """

  use LemonCore.Env.Registry

  @declarations [
    %{
      name: :lemon_agent_profiles_cwd,
      env_var: "LEMON_AGENT_PROFILES_CWD",
      aliases: [],
      type: :string,
      default: nil,
      doc: "Working directory override used to resolve router agent profiles.",
      secret?: false,
      required?: false,
      area: :endpoints,
      apps: [:lemon_router]
    },
    %{
      name: :lemon_router_health_port,
      env_var: "LEMON_ROUTER_HEALTH_PORT",
      aliases: [],
      type: :integer,
      default: nil,
      doc: "Port the router health-check endpoint listens on.",
      secret?: false,
      required?: false,
      area: :endpoints,
      apps: [:lemon_router]
    }
  ]
end
