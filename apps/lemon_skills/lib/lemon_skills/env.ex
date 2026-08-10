defmodule LemonSkills.Env do
  @moduledoc """
  Environment variables read by `lemon_skills` — skill discovery and synthesis.

  Aggregated by `LemonCore.Env` through the `:env_registries` list; see
  `LemonCore.Env.Registry`.
  """

  use LemonCore.Env.Registry

  @declarations [
    %{
      name: :deepgram_api_key,
      env_var: "DEEPGRAM_API_KEY",
      aliases: [],
      type: :string,
      default: nil,
      doc: "Deepgram API key for voice transcription (ecosystem-standard name).",
      secret?: true,
      required?: false,
      area: :gateway_voice,
      apps: [:lemon_gateway]
    },
    %{
      name: :elevenlabs_api_key,
      env_var: "ELEVENLABS_API_KEY",
      aliases: [],
      type: :string,
      default: nil,
      doc: "ElevenLabs API key for voice synthesis (ecosystem-standard name).",
      secret?: true,
      required?: false,
      area: :gateway_voice,
      apps: [:lemon_gateway]
    },
    %{
      name: :elevenlabs_voice_id,
      env_var: "ELEVENLABS_VOICE_ID",
      aliases: [],
      type: :string,
      default: "21m00Tcm4TlvDq8ikWAM",
      doc: "ElevenLabs voice id used for voice synthesis.",
      secret?: false,
      required?: false,
      area: :gateway_voice,
      apps: [:lemon_gateway]
    },
    %{
      name: :lemon_agent_dir,
      env_var: "LEMON_AGENT_DIR",
      aliases: [],
      type: :string,
      default: nil,
      doc: "Override for the `.lemon` agent state directory.",
      secret?: false,
      required?: false,
      area: :runtime,
      apps: [:coding_agent, :lemon_skills]
    },
    %{
      name: :lemon_agent_id,
      env_var: "LEMON_AGENT_ID",
      aliases: [],
      type: :string,
      default: "default",
      doc: "Default agent id used by `mix lemon.skill` CLI operations.",
      secret?: false,
      required?: false,
      area: :skills,
      apps: [:lemon_skills]
    },
    %{
      name: :lemon_harness_skills_dir,
      env_var: "LEMON_HARNESS_SKILLS_DIR",
      aliases: [],
      type: :string,
      default: nil,
      doc: "Override directory for harness/eval skill fixtures.",
      secret?: false,
      required?: false,
      area: :skills,
      apps: [:lemon_skills]
    },
    %{
      name: :lemon_mcp_disabled,
      env_var: "LEMON_MCP_DISABLED",
      aliases: [],
      type: :boolean,
      default: false,
      doc: "Kill switch to disable all MCP tool sources.",
      secret?: false,
      required?: false,
      area: :skills,
      apps: [:lemon_skills]
    },
    %{
      name: :lemon_mcp_servers,
      env_var: "LEMON_MCP_SERVERS",
      aliases: [],
      type: :string,
      default: nil,
      doc: "JSON-encoded list of MCP server configs, overriding the TOML/app config.",
      secret?: false,
      required?: false,
      area: :skills,
      apps: [:lemon_skills]
    }
  ]
end
