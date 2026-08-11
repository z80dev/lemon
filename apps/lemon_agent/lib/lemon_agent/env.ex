defmodule LemonAgent.Env do
  @moduledoc """
  Environment variables read by `agent_core` — the agent loop, model runtime, and credential resolution.

  Aggregated by `LemonCore.Env` through the `:env_registries` list; see
  `LemonCore.Env.Registry`.
  """

  use LemonCore.Env.Registry

  @declarations [
    %{
      name: :aws_access_key_id,
      env_var: "AWS_ACCESS_KEY_ID",
      aliases: [],
      type: :string,
      default: nil,
      doc: "AWS access key id for Bedrock (ecosystem-standard name).",
      secret?: true,
      required?: false,
      area: :provider_secrets,
      apps: [:lemon_core, :lemon_agent]
    },
    %{
      name: :aws_profile,
      env_var: "AWS_PROFILE",
      aliases: [],
      type: :string,
      default: nil,
      doc: "Named AWS CLI credentials profile to resolve Bedrock credentials from.",
      secret?: false,
      required?: false,
      area: :provider_secrets,
      apps: [:lemon_agent]
    },
    %{
      name: :aws_secret_access_key,
      env_var: "AWS_SECRET_ACCESS_KEY",
      aliases: [],
      type: :string,
      default: nil,
      doc: "AWS secret access key for Bedrock (ecosystem-standard name).",
      secret?: true,
      required?: false,
      area: :provider_secrets,
      apps: [:lemon_core, :lemon_agent]
    }
  ]
end
