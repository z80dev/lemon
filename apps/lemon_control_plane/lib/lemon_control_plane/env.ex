defmodule LemonControlPlane.Env do
  @moduledoc """
  Environment variables read by `lemon_control_plane` — the control-plane HTTP surface.

  Aggregated by `LemonCore.Env` through the `:env_registries` list; see
  `LemonCore.Env.Registry`.
  """

  use LemonCore.Env.Registry

  @declarations [
    %{
      name: :lemon_acp_api_token,
      env_var: "LEMON_ACP_API_TOKEN",
      aliases: [],
      type: :string,
      default: nil,
      doc: "Bearer token required for the ACP (agent control protocol) HTTP API.",
      secret?: true,
      required?: false,
      area: :endpoints,
      apps: [:lemon_control_plane]
    },
    %{
      name: :lemon_control_plane_port,
      env_var: "LEMON_CONTROL_PLANE_PORT",
      aliases: [],
      type: :integer,
      default: nil,
      doc: "Port the control-plane HTTP server listens on.",
      secret?: false,
      required?: false,
      area: :endpoints,
      apps: [:lemon_control_plane]
    },
    %{
      name: :lemon_control_plane_operator_token,
      env_var: "LEMON_CONTROL_PLANE_OPERATOR_TOKEN",
      aliases: [],
      type: :string,
      default: nil,
      doc: "Shared operator credential required by control-plane WebSocket operator connections.",
      secret?: true,
      required?: false,
      area: :endpoints,
      apps: [:lemon_control_plane]
    },
    %{
      name: :lemon_control_plane_allow_unauthenticated_loopback,
      env_var: "LEMON_CONTROL_PLANE_ALLOW_UNAUTHENTICATED_LOOPBACK",
      aliases: [],
      type: :boolean,
      default: false,
      doc:
        "Explicitly allow legacy tokenless WebSocket operator access from direct loopback peers.",
      secret?: false,
      required?: false,
      area: :endpoints,
      apps: [:lemon_control_plane]
    },
    %{
      name: :lemon_openai_compat_api_token,
      env_var: "LEMON_OPENAI_COMPAT_API_TOKEN",
      aliases: ["LEMON_OPENAI_COMPAT_TOKEN"],
      type: :string,
      default: nil,
      doc: "Bearer token required for the OpenAI-compatible HTTP API.",
      secret?: true,
      required?: false,
      area: :endpoints,
      apps: [:lemon_control_plane]
    },
    %{
      name: :lemon_openai_compat_image_url_allowed_hosts,
      env_var: "LEMON_OPENAI_COMPAT_IMAGE_URL_ALLOWED_HOSTS",
      aliases: ["LEMON_OPENAI_COMPAT_IMAGE_HOST_ALLOWLIST"],
      type: :list,
      default: [],
      doc: "Comma-separated hostname allowlist for OpenAI-compat image URL fetch.",
      secret?: false,
      required?: false,
      area: :endpoints,
      apps: [:lemon_control_plane]
    },
    %{
      name: :lemon_openai_compat_image_url_fetch,
      env_var: "LEMON_OPENAI_COMPAT_IMAGE_URL_FETCH",
      aliases: [],
      type: :boolean,
      default: false,
      doc: "Whether the OpenAI-compat endpoint is allowed to fetch image URLs from messages.",
      secret?: false,
      required?: false,
      area: :endpoints,
      apps: [:lemon_control_plane]
    }
  ]
end
