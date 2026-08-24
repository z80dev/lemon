defmodule LemonHoncho.Env do
  @moduledoc """
  Environment variables read by `lemon_honcho` — the Honcho memory satellite.

  Two prefixes appear here and the split is deliberate. `HONCHO_*` names the
  variables that address the Honcho service itself (credentials, endpoint,
  workspace, peers) and matches the spelling used by Honcho's own SDKs, so an
  operator who already exports them for another client gets a working Lemon
  integration for free. `LEMON_HONCHO_*` names the knobs that are ours: whether
  the integration runs at all, how memory reaches the model, and how much of a
  turn's budget it may spend.

  Aggregated by `LemonCore.Env` through the `:env_registries` list; see
  `LemonCore.Env.Registry`. The declarations are the documented contract —
  `LemonHoncho.Config` is what reads them, and it treats every value as
  advisory: an unparseable number or a misspelled enum falls back to the
  default below rather than failing the boot.
  """

  use LemonCore.Env.Registry

  @declarations [
    %{
      name: :honcho_api_key,
      env_var: "HONCHO_API_KEY",
      aliases: [],
      type: :string,
      default: nil,
      doc: "Honcho API key. Presence of this (or HONCHO_BASE_URL) enables the integration.",
      secret?: true,
      required?: false,
      area: :honcho,
      apps: [:lemon_honcho]
    },
    %{
      name: :honcho_base_url,
      env_var: "HONCHO_BASE_URL",
      aliases: [],
      type: :string,
      default: nil,
      doc: "Base URL of the Honcho API. Set this to point at a self-hosted deployment.",
      secret?: false,
      required?: false,
      area: :honcho,
      apps: [:lemon_honcho]
    },
    %{
      name: :honcho_environment,
      env_var: "HONCHO_ENVIRONMENT",
      aliases: [],
      type: :string,
      default: "production",
      doc: "Honcho deployment to talk to when no base URL is given (production, demo, local).",
      secret?: false,
      required?: false,
      area: :honcho,
      apps: [:lemon_honcho]
    },
    %{
      name: :honcho_workspace,
      env_var: "HONCHO_WORKSPACE",
      aliases: [],
      type: :string,
      default: "lemon",
      doc: "Honcho workspace that owns every peer, session and conclusion Lemon writes.",
      secret?: false,
      required?: false,
      area: :honcho,
      apps: [:lemon_honcho]
    },
    %{
      name: :honcho_peer,
      env_var: "HONCHO_PEER",
      aliases: [],
      type: :string,
      default: nil,
      doc: "Peer id representing the human. Defaults to the sanitized $USER, then \"user\".",
      secret?: false,
      required?: false,
      area: :honcho,
      apps: [:lemon_honcho]
    },
    %{
      name: :honcho_ai_peer,
      env_var: "HONCHO_AI_PEER",
      aliases: [],
      type: :string,
      default: "lemon",
      doc: "Peer id representing the assistant side of the conversation.",
      secret?: false,
      required?: false,
      area: :honcho,
      apps: [:lemon_honcho]
    },
    %{
      name: :honcho_timeout_ms,
      env_var: "HONCHO_TIMEOUT_MS",
      aliases: [],
      type: :integer,
      default: 30_000,
      doc:
        "Timeout for one attempt at a Honcho HTTP call, in milliseconds. A turn-path call may retry a transient failure twice; the diagnostics in `mix lemon.honcho` do not, so there it is the whole bound.",
      secret?: false,
      required?: false,
      area: :honcho,
      apps: [:lemon_honcho]
    },
    %{
      name: :lemon_honcho_enabled,
      env_var: "LEMON_HONCHO_ENABLED",
      aliases: [],
      type: :boolean,
      default: true,
      doc:
        "Master switch, on by default: a key or base URL alone activates the integration. Set false to ignore a key that stays exported.",
      secret?: false,
      required?: false,
      area: :honcho,
      apps: [:lemon_honcho]
    },
    %{
      name: :lemon_honcho_recall_mode,
      env_var: "LEMON_HONCHO_RECALL_MODE",
      aliases: [],
      type: :string,
      default: "hybrid",
      doc:
        "How memory reaches the model: hybrid (injection + tools), context (injection only; the honcho_* tools are inactive), or tools (tools only; nothing injected).",
      secret?: false,
      required?: false,
      area: :honcho,
      apps: [:lemon_honcho]
    },
    %{
      name: :lemon_honcho_session_strategy,
      env_var: "LEMON_HONCHO_SESSION_STRATEGY",
      aliases: [],
      type: :string,
      default: "per-directory",
      doc: "What a Honcho session maps to: per-session, per-directory, per-repo, or global.",
      secret?: false,
      required?: false,
      area: :honcho,
      apps: [:lemon_honcho]
    },
    %{
      name: :lemon_honcho_context_cadence,
      env_var: "LEMON_HONCHO_CONTEXT_CADENCE",
      aliases: [],
      type: :integer,
      default: 1,
      doc: "Refresh the injected session context every N turns (1 = every turn).",
      secret?: false,
      required?: false,
      area: :honcho,
      apps: [:lemon_honcho]
    },
    %{
      name: :lemon_honcho_dialectic_cadence,
      env_var: "LEMON_HONCHO_DIALECTIC_CADENCE",
      aliases: [],
      type: :integer,
      default: 2,
      doc: "Run the (slower, reasoned) dialectic query every N turns.",
      secret?: false,
      required?: false,
      area: :honcho,
      apps: [:lemon_honcho]
    },
    %{
      name: :lemon_honcho_context_tokens,
      env_var: "LEMON_HONCHO_CONTEXT_TOKENS",
      aliases: [],
      type: :integer,
      default: nil,
      doc: "Token budget asked of Honcho for session context. Unset lets Honcho decide.",
      secret?: false,
      required?: false,
      area: :honcho,
      apps: [:lemon_honcho]
    },
    %{
      name: :lemon_honcho_dialectic_max_chars,
      env_var: "LEMON_HONCHO_DIALECTIC_MAX_CHARS",
      aliases: [],
      type: :integer,
      default: 600,
      doc: "Hard cap on the dialectic answer spliced into the prompt, in characters.",
      secret?: false,
      required?: false,
      area: :honcho,
      apps: [:lemon_honcho]
    },
    %{
      name: :lemon_honcho_reasoning_level,
      env_var: "LEMON_HONCHO_REASONING_LEVEL",
      aliases: [],
      type: :string,
      default: "low",
      doc:
        "Reasoning budget Honcho spends on dialectic queries: minimal, low, medium, high, max.",
      secret?: false,
      required?: false,
      area: :honcho,
      apps: [:lemon_honcho]
    },
    %{
      name: :lemon_honcho_observation_mode,
      env_var: "LEMON_HONCHO_OBSERVATION_MODE",
      aliases: [],
      type: :string,
      default: "directional",
      doc: "Peer observation preset: directional (both peers observe) or unified (one model).",
      secret?: false,
      required?: false,
      area: :honcho,
      apps: [:lemon_honcho]
    },
    %{
      name: :lemon_honcho_save_messages,
      env_var: "LEMON_HONCHO_SAVE_MESSAGES",
      aliases: [],
      type: :boolean,
      default: true,
      doc:
        "Whether turns are written back to Honcho. False makes the integration read-only: no uploads, and the profile write and conclusion create/delete are refused.",
      secret?: false,
      required?: false,
      area: :honcho,
      apps: [:lemon_honcho]
    },
    %{
      name: :lemon_honcho_inject_in_subagents,
      env_var: "LEMON_HONCHO_INJECT_IN_SUBAGENTS",
      aliases: [],
      type: :boolean,
      default: false,
      doc: "Whether subagent runs also get memory injected. Off by default; subagents are cheap.",
      secret?: false,
      required?: false,
      area: :honcho,
      apps: [:lemon_honcho]
    },
    %{
      name: :lemon_honcho_first_turn_wait_ms,
      env_var: "LEMON_HONCHO_FIRST_TURN_WAIT_MS",
      aliases: [],
      type: :integer,
      default: 3_000,
      doc:
        "How long a session's cold first turn may block waiting for memory. The value plus a 200ms margin is clamped to prompt assembly's 3000ms contributor ceiling, so values above 2800 buy no more time; 0 disables the wait.",
      secret?: false,
      required?: false,
      area: :honcho,
      apps: [:lemon_honcho]
    },
    %{
      name: :lemon_honcho_message_max_chars,
      env_var: "LEMON_HONCHO_MESSAGE_MAX_CHARS",
      aliases: [],
      type: :integer,
      default: 25_000,
      doc: "Per-message truncation applied before a turn is uploaded to Honcho.",
      secret?: false,
      required?: false,
      area: :honcho,
      apps: [:lemon_honcho]
    }
  ]
end
