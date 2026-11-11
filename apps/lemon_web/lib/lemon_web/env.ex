defmodule LemonWeb.Env do
  @moduledoc """
  Environment variables read by `lemon_web` — the web endpoint.

  Aggregated by `LemonCore.Env` through the `:env_registries` list; see
  `LemonCore.Env.Registry`.
  """

  use LemonCore.Env.Registry

  @declarations [
    %{
      name: :lemon_web_bind_ip,
      env_var: "LEMON_WEB_BIND_IP",
      aliases: [],
      type: :string,
      default: "127.0.0.1",
      doc:
        "LemonWeb bind address; non-loopback requires an operator token and TLS should terminate in front.",
      secret?: false,
      required?: false,
      area: :endpoints,
      apps: [:lemon_web]
    },
    %{
      name: :lemon_web_host,
      env_var: "LEMON_WEB_HOST",
      aliases: [],
      type: :string,
      default: "localhost",
      doc: "Public hostname for the LemonWeb prod endpoint.",
      secret?: false,
      required?: false,
      area: :endpoints,
      apps: [:lemon_web]
    },
    %{
      name: :lemon_web_port,
      env_var: "LEMON_WEB_PORT",
      aliases: [],
      type: :integer,
      default: 4080,
      doc: "Port LemonWeb listens on.",
      secret?: false,
      required?: false,
      area: :endpoints,
      apps: [:lemon_web]
    },
    %{
      name: :lemon_web_url_scheme,
      env_var: "LEMON_WEB_URL_SCHEME",
      aliases: [],
      type: :string,
      default: "https",
      doc: "Public URL scheme for generated LemonWeb links (http or https).",
      secret?: false,
      required?: false,
      area: :endpoints,
      apps: [:lemon_web]
    },
    %{
      name: :lemon_web_url_port,
      env_var: "LEMON_WEB_URL_PORT",
      aliases: [],
      type: :integer,
      default: 443,
      doc: "Public URL port for generated LemonWeb links.",
      secret?: false,
      required?: false,
      area: :endpoints,
      apps: [:lemon_web]
    },
    %{
      name: :lemon_web_secret_key_base,
      env_var: "LEMON_WEB_SECRET_KEY_BASE",
      aliases: [],
      type: :string,
      default: nil,
      doc: "Phoenix secret_key_base for the LemonWeb prod endpoint.",
      secret?: true,
      required?: false,
      area: :endpoints,
      apps: [:lemon_web]
    },
    %{
      name: :lemon_web_uploads_dir,
      env_var: "LEMON_WEB_UPLOADS_DIR",
      aliases: [],
      type: :string,
      default: nil,
      doc: "Directory used for LemonWeb file uploads.",
      secret?: false,
      required?: false,
      area: :endpoints,
      apps: [:lemon_web]
    }
  ]
end
