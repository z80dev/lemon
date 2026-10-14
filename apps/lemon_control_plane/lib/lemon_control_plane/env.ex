defmodule LemonControlPlane.Env do
  @moduledoc """
  Environment variables read by `lemon_control_plane` — the control-plane HTTP surface.

  Aggregated by `LemonCore.Env` through the `:env_registries` list; see
  `LemonCore.Env.Registry`.
  """

  use LemonCore.Env.Registry

  @declarations [
    %{
      name: :lemon_control_plane_public_ws_url,
      env_var: "LEMON_CONTROL_PLANE_PUBLIC_WS_URL",
      aliases: [],
      type: :string,
      default: nil,
      doc: "Reachable secure control-plane WebSocket URL embedded in node invitations; ws is allowed only for loopback.",
      secret?: false,
      required?: false,
      area: :execution_nodes,
      apps: [:lemon_control_plane]
    },
    %{
      name: :lemon_node_source_checkout,
      env_var: "LEMON_NODE_SOURCE_CHECKOUT",
      aliases: [],
      type: :string,
      default: nil,
      doc: "Absolute destination-local integrated source checkout used by node invite commands.",
      secret?: false,
      required?: false,
      area: :execution_nodes,
      apps: [:lemon_control_plane]
    },
    %{
      name: :lemon_node_install_version,
      env_var: "LEMON_NODE_INSTALL_VERSION",
      aliases: [],
      type: :string,
      default: nil,
      doc: "Exact operator-supported node artifact CalVer; requires an HTTPS node install base URL and actual feature checks.",
      secret?: false,
      required?: false,
      area: :execution_nodes,
      apps: [:lemon_control_plane]
    },
    %{
      name: :lemon_node_install_base_url,
      env_var: "LEMON_NODE_INSTALL_BASE_URL",
      aliases: [],
      type: :string,
      default: nil,
      doc: "HTTPS operator-supported pinned node artifact base URL passed to the existing installer; never defaults to published artifacts.",
      secret?: false,
      required?: false,
      area: :execution_nodes,
      apps: [:lemon_control_plane]
    },
    %{
      name: :lemon_gateway_enable_a2a,
      env_var: "LEMON_GATEWAY_ENABLE_A2A",
      aliases: [],
      type: :boolean,
      default: false,
      doc: "Enable the A2A peer listener.",
      secret?: false,
      required?: false,
      area: :endpoints,
      apps: [:lemon_control_plane]
    },
    %{
      name: :lemon_a2a_host,
      env_var: "LEMON_A2A_HOST",
      aliases: [],
      type: :string,
      default: nil,
      doc: "Host address for the A2A peer listener.",
      secret?: false,
      required?: false,
      area: :endpoints,
      apps: [:lemon_control_plane]
    },
    %{
      name: :lemon_a2a_port,
      env_var: "LEMON_A2A_PORT",
      aliases: [],
      type: :integer,
      default: nil,
      doc: "Port for the A2A peer listener.",
      secret?: false,
      required?: false,
      area: :endpoints,
      apps: [:lemon_control_plane]
    },
    %{
      name: :lemon_a2a_public_url,
      env_var: "LEMON_A2A_PUBLIC_URL",
      aliases: [],
      type: :string,
      default: nil,
      doc: "Public A2A JSON-RPC URL advertised in Lemon's Agent Card.",
      secret?: false,
      required?: false,
      area: :endpoints,
      apps: [:lemon_control_plane]
    },
    %{
      name: :lemon_a2a_reply_timeout_ms,
      env_var: "LEMON_A2A_REPLY_TIMEOUT_MS",
      aliases: [],
      type: :integer,
      default: nil,
      doc: "Maximum synchronous wait for an A2A peer run.",
      secret?: false,
      required?: false,
      area: :endpoints,
      apps: [:lemon_control_plane]
    },
    %{
      name: :lemon_a2a_rate_limit_per_minute,
      env_var: "LEMON_A2A_RATE_LIMIT_PER_MINUTE",
      aliases: [],
      type: :integer,
      default: nil,
      doc: "Per-peer A2A JSON-RPC request limit per minute.",
      secret?: false,
      required?: false,
      area: :endpoints,
      apps: [:lemon_control_plane]
    },
    %{
      name: :lemon_a2a_max_context_turns,
      env_var: "LEMON_A2A_MAX_CONTEXT_TURNS",
      aliases: [],
      type: :integer,
      default: nil,
      doc: "Maximum accepted inbound turns per A2A context.",
      secret?: false,
      required?: false,
      area: :endpoints,
      apps: [:lemon_control_plane]
    },
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
