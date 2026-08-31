defmodule LemonBrowser.Env do
  @moduledoc """
  Environment variables read by `lemon_browser` — the headless browser integration.

  Aggregated by `LemonCore.Env` through the `:env_registries` list; see
  `LemonCore.Env.Registry`.
  """

  use LemonCore.Env.Registry

  @declarations [
    %{
      name: :lemon_browser_backend,
      env_var: "LEMON_BROWSER_BACKEND",
      aliases: [],
      type: :string,
      default: "local",
      doc:
        "Browser backend id: local, controller, hybrid, browserbase, browser_use, firecrawl, or camofox.",
      secret?: false,
      required?: false,
      area: :browser,
      apps: [:lemon_browser]
    },
    %{
      name: :lemon_browser_hybrid_local_backend,
      env_var: "LEMON_BROWSER_HYBRID_LOCAL_BACKEND",
      aliases: [],
      type: :string,
      default: "local",
      doc: "Local/private backend selected by the hybrid browser router.",
      secret?: false,
      required?: false,
      area: :browser,
      apps: [:lemon_browser]
    },
    %{
      name: :lemon_browser_hybrid_public_backend,
      env_var: "LEMON_BROWSER_HYBRID_PUBLIC_BACKEND",
      aliases: [],
      type: :string,
      default: nil,
      doc: "Explicit hosted backend selected by the hybrid router for public URLs.",
      secret?: false,
      required?: false,
      area: :browser,
      apps: [:lemon_browser]
    },
    %{
      name: :lemon_cua_driver_cmd,
      env_var: "LEMON_CUA_DRIVER_CMD",
      aliases: [],
      type: :string,
      default: nil,
      doc: "Path or executable name for the cua-driver used by computer_use.",
      secret?: false,
      required?: false,
      area: :browser,
      apps: [:lemon_browser]
    },
    %{
      name: :browserbase_api_key,
      env_var: "BROWSERBASE_API_KEY",
      aliases: [],
      type: :string,
      default: nil,
      doc: "Browserbase API key for hosted browser sessions.",
      secret?: true,
      required?: false,
      area: :browser,
      apps: [:lemon_browser]
    },
    %{
      name: :browserbase_project_id,
      env_var: "BROWSERBASE_PROJECT_ID",
      aliases: [],
      type: :string,
      default: nil,
      doc: "Browserbase project id for hosted browser sessions.",
      secret?: false,
      required?: false,
      area: :browser,
      apps: [:lemon_browser]
    },
    %{
      name: :browser_use_api_key,
      env_var: "BROWSER_USE_API_KEY",
      aliases: [],
      type: :string,
      default: nil,
      doc: "Browser Use Cloud API key for hosted browser sessions.",
      secret?: true,
      required?: false,
      area: :browser,
      apps: [:lemon_browser]
    },
    %{
      name: :camofox_url,
      env_var: "CAMOFOX_URL",
      aliases: [],
      type: :string,
      default: nil,
      doc: "Base URL for a Camofox REST/Firefox browser server.",
      secret?: false,
      required?: false,
      area: :browser,
      apps: [:lemon_browser]
    },
    %{
      name: :camofox_api_key,
      env_var: "CAMOFOX_API_KEY",
      aliases: [],
      type: :string,
      default: nil,
      doc: "Optional bearer key for the configured Camofox server.",
      secret?: true,
      required?: false,
      area: :browser,
      apps: [:lemon_browser]
    },
    %{
      name: :lemon_browser_attach_only,
      env_var: "LEMON_BROWSER_ATTACH_ONLY",
      aliases: [],
      type: :boolean,
      default: false,
      doc:
        "Whether the browser tool only attaches to an existing browser instead of launching one.",
      secret?: false,
      required?: false,
      area: :browser,
      apps: [:lemon_browser]
    },
    %{
      name: :lemon_browser_cdp_endpoint,
      env_var: "LEMON_BROWSER_CDP_ENDPOINT",
      aliases: [],
      type: :string,
      default: nil,
      doc:
        "Chrome DevTools Protocol websocket endpoint to attach to instead of launching a browser.",
      secret?: false,
      required?: false,
      area: :browser,
      apps: [:lemon_browser]
    },
    %{
      name: :lemon_browser_cdp_port,
      env_var: "LEMON_BROWSER_CDP_PORT",
      aliases: [],
      type: :integer,
      default: 18_800,
      doc:
        "Local CDP port used when launching a managed browser instance. Only positive " <>
          "integers are accepted (0/negative/unparseable fall back to the default); " <>
          "resolved with a bespoke parser in LemonBrowser.LocalServer, not the standard " <>
          ":integer cast.",
      secret?: false,
      required?: false,
      area: :browser,
      apps: [:lemon_browser]
    },
    %{
      name: :lemon_browser_driver_path,
      env_var: "LEMON_BROWSER_DRIVER_PATH",
      aliases: [],
      type: :string,
      default: nil,
      doc: "Path to the browser automation driver binary.",
      secret?: false,
      required?: false,
      area: :browser,
      apps: [:lemon_browser]
    },
    %{
      name: :lemon_browser_relay_port,
      env_var: "LEMON_BROWSER_RELAY_PORT",
      aliases: [],
      type: :integer,
      default: 9_224,
      doc: "Loopback port for the Manifest V3 existing-Chrome relay.",
      secret?: false,
      required?: false,
      area: :browser,
      apps: [:lemon_browser]
    },
    %{
      name: :lemon_browser_relay_token,
      env_var: "LEMON_BROWSER_RELAY_TOKEN",
      aliases: [],
      type: :string,
      default: nil,
      doc: "Required shared secret for the loopback extension and CDP relay.",
      secret?: true,
      required?: false,
      area: :browser,
      apps: [:lemon_browser]
    }
  ]
end
