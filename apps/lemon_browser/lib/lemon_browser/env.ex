defmodule LemonBrowser.Env do
  @moduledoc """
  Environment variables read by `lemon_browser` — the headless browser integration.

  Aggregated by `LemonCore.Env` through the `:env_registries` list; see
  `LemonCore.Env.Registry`.
  """

  use LemonCore.Env.Registry

  @declarations [
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
    }
  ]
end
