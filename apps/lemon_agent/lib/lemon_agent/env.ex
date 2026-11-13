defmodule LemonAgent.Env do
  @moduledoc """
  Environment variables read by `lemon_agent` — the agent loop, model runtime, and credential resolution.

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
    },
    %{
      name: :omp_auth_broker_url,
      env_var: "OMP_AUTH_BROKER_URL",
      aliases: [],
      type: :string,
      default: nil,
      doc:
        "omp auth broker base URL for `auth_source = \"omp_broker\"` providers (default http://127.0.0.1:8765); a same-named Lemon secret also works.",
      secret?: false,
      required?: false,
      area: :provider_secrets,
      apps: [:lemon_agent]
    },
    %{
      name: :omp_auth_broker_token,
      env_var: "OMP_AUTH_BROKER_TOKEN",
      aliases: [],
      type: :string,
      default: nil,
      doc:
        "omp auth broker bearer token; defaults to omp's `auth-broker.token`. A same-named Lemon secret also works.",
      secret?: true,
      required?: false,
      area: :provider_secrets,
      apps: [:lemon_agent]
    },
    %{
      name: :omp_auth_gateway_token,
      env_var: "OMP_AUTH_GATEWAY_TOKEN",
      aliases: [],
      type: :string,
      default: nil,
      doc: "Bearer for the `omp_gateway` provider; defaults to omp's `auth-gateway.token`.",
      secret?: true,
      required?: false,
      area: :provider_secrets,
      apps: [:lemon_agent]
    },
    %{
      name: :omp_auth_gateway_url,
      env_var: "OMP_AUTH_GATEWAY_URL",
      aliases: [],
      type: :string,
      default: nil,
      doc:
        "Base URL (`/v1` root) of the omp auth gateway used by the `omp_gateway` provider (default http://127.0.0.1:4000/v1).",
      secret?: false,
      required?: false,
      area: :provider_secrets,
      apps: [:lemon_agent]
    }
  ]
end
