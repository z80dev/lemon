defmodule XApi.Env do
  @moduledoc """
  Environment variables read by `x_api` — the X (Twitter) API client.

  Aggregated by `LemonCore.Env` through the `:env_registries` list; see
  `LemonCore.Env.Registry`.
  """

  use LemonCore.Env.Registry

  @declarations [
    %{
      name: :x_api_access_token,
      env_var: "X_API_ACCESS_TOKEN",
      aliases: [],
      type: :string,
      default: nil,
      doc: "X (Twitter) API OAuth1 access token.",
      secret?: true,
      required?: false,
      area: :x_api,
      apps: [:x_api]
    },
    %{
      name: :x_api_access_token_secret,
      env_var: "X_API_ACCESS_TOKEN_SECRET",
      aliases: [],
      type: :string,
      default: nil,
      doc: "X (Twitter) API OAuth1 access token secret.",
      secret?: true,
      required?: false,
      area: :x_api,
      apps: [:x_api]
    },
    %{
      name: :x_api_consumer_key,
      env_var: "X_API_CONSUMER_KEY",
      aliases: [],
      type: :string,
      default: nil,
      doc: "X (Twitter) API OAuth1 consumer key.",
      secret?: true,
      required?: false,
      area: :x_api,
      apps: [:x_api]
    },
    %{
      name: :x_api_consumer_secret,
      env_var: "X_API_CONSUMER_SECRET",
      aliases: [],
      type: :string,
      default: nil,
      doc: "X (Twitter) API OAuth1 consumer secret.",
      secret?: true,
      required?: false,
      area: :x_api,
      apps: [:x_api]
    }
  ]
end
