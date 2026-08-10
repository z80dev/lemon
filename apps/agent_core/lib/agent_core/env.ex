defmodule AgentCore.Env do
  @moduledoc """
  Environment variables read by `agent_core` — the agent loop, model runtime, and credential resolution.

  Aggregated by `LemonCore.Env` through the `:env_registries` list; see
  `LemonCore.Env.Registry`.
  """

  use LemonCore.Env.Registry

  @declarations [
    %{
      name: :factory_api_key,
      env_var: "FACTORY_API_KEY",
      aliases: [],
      type: :string,
      default: nil,
      doc: "Factory (Droid CLI) API key.",
      secret?: true,
      required?: false,
      area: :cli_runners,
      apps: [:agent_core]
    },
    %{
      name: :lemon_claude_yolo,
      env_var: "LEMON_CLAUDE_YOLO",
      aliases: [],
      type: :boolean,
      default: false,
      doc:
        "Whether the Claude CLI runner skips permission prompts (`--dangerously-skip-permissions`-style).",
      secret?: false,
      required?: false,
      area: :cli_runners,
      apps: [:agent_core]
    },
    %{
      name: :lemon_codex_auto_approve,
      env_var: "LEMON_CODEX_AUTO_APPROVE",
      aliases: [],
      type: :boolean,
      default: false,
      doc: "Whether the Codex CLI runner auto-approves tool calls.",
      secret?: false,
      required?: false,
      area: :cli_runners,
      apps: [:agent_core]
    },
    %{
      name: :lemon_codex_extra_args,
      env_var: "LEMON_CODEX_EXTRA_ARGS",
      aliases: [],
      type: :list,
      default: [],
      doc: "Extra whitespace-separated CLI args appended to Codex invocations.",
      secret?: false,
      required?: false,
      area: :cli_runners,
      apps: [:agent_core]
    },
    %{
      name: :pi_coding_agent_dir,
      env_var: "PI_CODING_AGENT_DIR",
      aliases: [],
      type: :string,
      default: nil,
      doc: "Working directory override for the Pi coding-agent CLI runner.",
      secret?: false,
      required?: false,
      area: :cli_runners,
      apps: [:agent_core]
    },
    %{
      name: :pi_debug,
      env_var: "PI_DEBUG",
      aliases: [],
      type: :boolean,
      default: false,
      doc: "Debug flag for the Pi coding-agent CLI runner / CodingAgent.Config.",
      secret?: false,
      required?: false,
      area: :cli_runners,
      apps: [:coding_agent, :agent_core]
    },
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
      apps: [:lemon_core, :agent_core]
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
      apps: [:agent_core]
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
      apps: [:lemon_core, :agent_core]
    }
  ]
end
