defmodule LemonComputerUse.Env do
  @moduledoc """
  Environment variables read by `lemon_computer_use`, native app control through
  LCU. Aggregated by `LemonCore.Env` through the `:env_registries` list;
  `LemonComputerUse.Config` reads them.
  """

  use LemonCore.Env.Registry

  @declarations [
    %{
      name: :computer_use_enabled,
      env_var: "LEMON_COMPUTER_USE_ENABLED",
      aliases: [],
      type: :boolean,
      default: false,
      doc:
        "Opt in to native app control (`cua_js`/`cua_js_reset`) through the locally installed LCU runtime.",
      secret?: false,
      required?: false,
      area: :computer_use,
      apps: [:lemon_computer_use]
    },
    %{
      name: :computer_use_lcu_root,
      env_var: "LEMON_COMPUTER_USE_LCU_ROOT",
      aliases: [],
      type: :string,
      default: nil,
      doc:
        "Installed LCU release directory. Defaults to ~/.local/share/lcu/current (or /opt/lcu/current).",
      secret?: false,
      required?: false,
      area: :computer_use,
      apps: [:lemon_computer_use]
    },
    %{
      name: :computer_use_node,
      env_var: "LEMON_COMPUTER_USE_NODE",
      aliases: [],
      type: :string,
      default: nil,
      doc:
        "Node runtime for the LCU bridge. Defaults to LCU's own `<root>/agent-tools/node/bin/node`.",
      secret?: false,
      required?: false,
      area: :computer_use,
      apps: [:lemon_computer_use]
    },
    %{
      name: :computer_use_declined_origins,
      env_var: "LEMON_COMPUTER_USE_DECLINED_ORIGINS",
      aliases: [],
      type: :string,
      default: nil,
      doc:
        "Comma-separated website origins computer use always declines (for example a custom Lemon Bot web origin).",
      secret?: false,
      required?: false,
      area: :computer_use,
      apps: [:lemon_computer_use]
    },
    %{
      name: :computer_use_lemon_bot_public_url,
      env_var: "LEMON_BOT_PUBLIC_URL",
      aliases: [],
      type: :string,
      default: nil,
      doc:
        "The Lemon Bot backend's public origin (owned by the Lemon Bot backend); computer use declines it because its web client shows approvals.",
      secret?: false,
      required?: false,
      area: :computer_use,
      apps: [:lemon_computer_use]
    }
  ]
end
