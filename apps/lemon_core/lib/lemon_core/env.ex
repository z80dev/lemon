defmodule LemonCore.Env do
  @moduledoc """
  Typed, declarative environment-variable registry for Lemon.

  This module is the single place that *documents* every environment
  variable Lemon reads (`LemonCore.Env.all_declared/0`), plus a small set of
  typed accessors for reading them. It does not yet replace the scattered
  `System.get_env/1` call sites across the umbrella -- callers migrate to
  `LemonCore.Env.get/2` in a later phase. Until then, this registry is the
  living documentation: see `docs/config-registry.md` for the generated
  reference table.

  ## Usage

      # Look up a declared variable by name, applying its declared type,
      # aliases, and default:
      LemonCore.Env.get(:lemon_arena_poker_models)
      #=> ["anthropic:claude-sonnet-4-20250514", "openai:gpt-5"]

      LemonCore.Env.get(:lemon_web_port)
      #=> 4080

      # Raw (undeclared) typed reads, e.g. for one-off/local variables that
      # don't warrant a registry entry:
      LemonCore.Env.int("SOME_TIMEOUT_MS", 5_000)
      LemonCore.Env.bool("SOME_FLAG", false)
      LemonCore.Env.list("SOME_HOSTS")

      # Every declared variable, for tooling (e.g. `mix lemon.doctor`) or
      # generating docs:
      LemonCore.Env.all_declared()

  ## Declaration shape

  Each declared variable is a map with:

    * `:name` - atom key used with `get/2`, e.g. `:lemon_web_port`
    * `:env_var` - the canonical environment variable name
    * `:aliases` - legacy/fallback environment variable names checked (in
      order) if `:env_var` is unset. Existing grandfathered non-conforming
      names live here rather than as the primary `:env_var` -- see the
      naming convention section of `docs/config-registry.md`.
    * `:type` - one of `:string`, `:integer`, `:float`, `:boolean`, `:list`,
      `:bytes` (parsed via `LemonCore.Config.Helpers.get_env_bytes/2`)
    * `:default` - value used when nothing resolves from the environment
    * `:doc` - one-line human-readable description
    * `:secret?` - whether the *value* should be redacted in any reporting
      surface (see `LemonCore.Env.Resolved`)
    * `:required?` - reserved for call-site opt-in; `get/2` also accepts a
      per-call `required: true` option independent of this flag
    * `:area` - a coarse grouping used to organize `docs/config-registry.md`
    * `:apps` - umbrella app(s) that read this variable today

  ## Type casting

  Casting is delegated to `LemonCore.Config.Helpers`, the umbrella's
  existing env-parsing toolkit, so behavior (bool truthy/falsy spellings,
  duration/byte-size suffixes, list delimiters) stays consistent with
  every other config reader in the codebase.
  """

  alias LemonCore.Config.Helpers

  @type var_type :: :string | :integer | :float | :boolean | :list | :bytes

  @type declaration :: %{
          name: atom(),
          env_var: String.t(),
          aliases: [String.t()],
          type: var_type(),
          default: term(),
          doc: String.t(),
          secret?: boolean(),
          required?: boolean(),
          area: atom(),
          apps: [atom()]
        }

  @declarations [
    %{
      name: :lemon_base_delay_ms,
      env_var: "LEMON_BASE_DELAY_MS",
      aliases: [],
      type: :integer,
      default: 1000,
      doc: "Base backoff delay (ms) between retry attempts.",
      secret?: false,
      required?: false,
      area: :agent,
      apps: [:lemon_core]
    },
    %{
      name: :lemon_budget_max_children,
      env_var: "LEMON_BUDGET_MAX_CHILDREN",
      aliases: [],
      type: :integer,
      default: 5,
      doc: "Default max concurrent delegated sub-agent children per run.",
      secret?: false,
      required?: false,
      area: :agent,
      apps: [:lemon_core]
    },
    %{
      name: :lemon_compaction_enabled,
      env_var: "LEMON_COMPACTION_ENABLED",
      aliases: [],
      type: :boolean,
      default: true,
      doc: "Whether context compaction runs automatically as the transcript grows.",
      secret?: false,
      required?: false,
      area: :agent,
      apps: [:lemon_core]
    },
    %{
      name: :lemon_compaction_keep_recent_tokens,
      env_var: "LEMON_COMPACTION_KEEP_RECENT_TOKENS",
      aliases: [],
      type: :integer,
      default: 20000,
      doc: "Recent-token window kept verbatim (uncompacted) at the tail of the transcript.",
      secret?: false,
      required?: false,
      area: :agent,
      apps: [:lemon_core]
    },
    %{
      name: :lemon_compaction_reserve_tokens,
      env_var: "LEMON_COMPACTION_RESERVE_TOKENS",
      aliases: [],
      type: :integer,
      default: 16384,
      doc: "Token budget reserved (not compacted away) during compaction.",
      secret?: false,
      required?: false,
      area: :agent,
      apps: [:lemon_core]
    },
    %{
      name: :lemon_default_model,
      env_var: "LEMON_DEFAULT_MODEL",
      aliases: [],
      type: :string,
      default: "claude-sonnet-4-20250514",
      doc: "Default model id used when no per-run model is specified.",
      secret?: false,
      required?: false,
      area: :agent,
      apps: [:lemon_core]
    },
    %{
      name: :lemon_default_provider,
      env_var: "LEMON_DEFAULT_PROVIDER",
      aliases: [],
      type: :string,
      default: "anthropic",
      doc: "Default LLM provider id used when no per-run provider is specified.",
      secret?: false,
      required?: false,
      area: :agent,
      apps: [:lemon_core]
    },
    %{
      name: :lemon_default_thinking_level,
      env_var: "LEMON_DEFAULT_THINKING_LEVEL",
      aliases: [],
      type: :string,
      default: "medium",
      doc: "Default reasoning/thinking effort level for the agent loop.",
      secret?: false,
      required?: false,
      area: :agent,
      apps: [:lemon_core]
    },
    %{
      name: :lemon_extension_paths,
      env_var: "LEMON_EXTENSION_PATHS",
      aliases: [],
      type: :list,
      default: [],
      doc: "Comma-separated list of extra extension directories to load.",
      secret?: false,
      required?: false,
      area: :agent,
      apps: [:lemon_core]
    },
    %{
      name: :lemon_extensions_auto_load_default_paths,
      env_var: "LEMON_EXTENSIONS_AUTO_LOAD_DEFAULT_PATHS",
      aliases: [],
      type: :boolean,
      default: false,
      doc: "Whether default extension search paths are auto-loaded.",
      secret?: false,
      required?: false,
      area: :agent,
      apps: [:lemon_core]
    },
    %{
      name: :lemon_extensions_enabled,
      env_var: "LEMON_EXTENSIONS_ENABLED",
      aliases: [],
      type: :boolean,
      default: true,
      doc: "Whether the extensions subsystem is enabled.",
      secret?: false,
      required?: false,
      area: :agent,
      apps: [:lemon_core]
    },
    %{
      name: :lemon_max_retries,
      env_var: "LEMON_MAX_RETRIES",
      aliases: [],
      type: :integer,
      default: 3,
      doc: "Maximum retry attempts for a failing LLM call.",
      secret?: false,
      required?: false,
      area: :agent,
      apps: [:lemon_core]
    },
    %{
      name: :lemon_provider_fallback_providers,
      env_var: "LEMON_PROVIDER_FALLBACK_PROVIDERS",
      aliases: [],
      type: :list,
      default: [],
      doc: "Comma-separated fallback provider ids tried after the primary provider fails.",
      secret?: false,
      required?: false,
      area: :agent,
      apps: [:lemon_core]
    },
    %{
      name: :lemon_provider_routing_default_pool,
      env_var: "LEMON_PROVIDER_ROUTING_DEFAULT_POOL",
      aliases: [],
      type: :string,
      default: nil,
      doc: "Default credential pool name used for provider routing.",
      secret?: false,
      required?: false,
      area: :agent,
      apps: [:lemon_core]
    },
    %{
      name: :lemon_provider_routing_default_profile,
      env_var: "LEMON_PROVIDER_ROUTING_DEFAULT_PROFILE",
      aliases: [],
      type: :string,
      default: nil,
      doc: "Default provider routing profile name.",
      secret?: false,
      required?: false,
      area: :agent,
      apps: [:lemon_core]
    },
    %{
      name: :lemon_provider_routing_enabled,
      env_var: "LEMON_PROVIDER_ROUTING_ENABLED",
      aliases: [],
      type: :boolean,
      default: true,
      doc: "Whether multi-provider routing/fallback is enabled.",
      secret?: false,
      required?: false,
      area: :agent,
      apps: [:lemon_core]
    },
    %{
      name: :lemon_provider_routing_require_credentials,
      env_var: "LEMON_PROVIDER_ROUTING_REQUIRE_CREDENTIALS",
      aliases: [],
      type: :boolean,
      default: true,
      doc:
        "Whether provider routing requires resolvable credentials before selecting a provider.",
      secret?: false,
      required?: false,
      area: :agent,
      apps: [:lemon_core]
    },
    %{
      name: :lemon_retry_enabled,
      env_var: "LEMON_RETRY_ENABLED",
      aliases: [],
      type: :boolean,
      default: true,
      doc: "Whether transient LLM call failures are retried.",
      secret?: false,
      required?: false,
      area: :agent,
      apps: [:lemon_core]
    },
    %{
      name: :lemon_shell_command_prefix,
      env_var: "LEMON_SHELL_COMMAND_PREFIX",
      aliases: [],
      type: :string,
      default: nil,
      doc: "Command prefix prepended to every shell tool invocation.",
      secret?: false,
      required?: false,
      area: :agent,
      apps: [:lemon_core]
    },
    %{
      name: :lemon_shell_path,
      env_var: "LEMON_SHELL_PATH",
      aliases: [],
      type: :string,
      default: nil,
      doc: "Shell executable path used by the bash/shell tool.",
      secret?: false,
      required?: false,
      area: :agent,
      apps: [:lemon_core]
    },
    %{
      name: :lemon_theme,
      env_var: "LEMON_THEME",
      aliases: [],
      type: :string,
      default: "lemon",
      doc: "Agent-level theme name (distinct from the TUI theme).",
      secret?: false,
      required?: false,
      area: :agent,
      apps: [:lemon_core]
    },
    %{
      name: :lemon_ai_debug,
      env_var: "LEMON_AI_DEBUG",
      aliases: [],
      type: :boolean,
      default: false,
      doc: "Whether raw Anthropic SSE traffic is logged to a debug file.",
      secret?: false,
      required?: false,
      area: :ai_diagnostics,
      apps: [:ai]
    },
    %{
      name: :lemon_ai_debug_file,
      env_var: "LEMON_AI_DEBUG_FILE",
      aliases: [],
      type: :string,
      default: "/tmp/lemon_anthropic_sse.log",
      doc: "File path used for Anthropic SSE debug logging.",
      secret?: false,
      required?: false,
      area: :ai_diagnostics,
      apps: [:ai]
    },
    %{
      name: :lemon_ai_http_trace,
      env_var: "LEMON_AI_HTTP_TRACE",
      aliases: [],
      type: :boolean,
      default: false,
      doc: "Whether low-level HTTP request/response tracing is enabled for provider calls.",
      secret?: false,
      required?: false,
      area: :ai_diagnostics,
      apps: [:ai]
    },
    %{
      name: :lemon_ai_prompt_diagnostics,
      env_var: "LEMON_AI_PROMPT_DIAGNOSTICS",
      aliases: [],
      type: :boolean,
      default: false,
      doc: "Whether prompt diagnostics logging is enabled.",
      secret?: false,
      required?: false,
      area: :ai_diagnostics,
      apps: [:ai]
    },
    %{
      name: :lemon_ai_prompt_diagnostics_log_level,
      env_var: "LEMON_AI_PROMPT_DIAGNOSTICS_LOG_LEVEL",
      aliases: [],
      type: :string,
      default: nil,
      doc: "Log level used for prompt diagnostics output.",
      secret?: false,
      required?: false,
      area: :ai_diagnostics,
      apps: [:ai]
    },
    %{
      name: :lemon_ai_prompt_diagnostics_top_n,
      env_var: "LEMON_AI_PROMPT_DIAGNOSTICS_TOP_N",
      aliases: [],
      type: :integer,
      default: nil,
      doc: "Number of top prompt-diagnostics entries to report.",
      secret?: false,
      required?: false,
      area: :ai_diagnostics,
      apps: [:ai]
    },
    %{
      name: :lemon_anthropic_claude_path,
      env_var: "LEMON_ANTHROPIC_CLAUDE_PATH",
      aliases: [],
      type: :string,
      default: nil,
      doc: "Override path to the `claude` executable used for Anthropic OAuth.",
      secret?: false,
      required?: false,
      area: :ai_diagnostics,
      apps: [:ai]
    },
    %{
      name: :lemon_kimi_max_request_messages,
      env_var: "LEMON_KIMI_MAX_REQUEST_MESSAGES",
      aliases: [],
      type: :integer,
      default: nil,
      doc: "Max message-history length sent per request to Kimi (history-limited provider).",
      secret?: false,
      required?: false,
      area: :ai_diagnostics,
      apps: [:ai]
    },
    %{
      name: :pi_cache_retention,
      env_var: "PI_CACHE_RETENTION",
      aliases: [],
      type: :string,
      default: nil,
      doc:
        "When set to \"long\", requests 24h prompt-cache retention from OpenAI-compatible providers.",
      secret?: false,
      required?: false,
      area: :ai_diagnostics,
      apps: [:ai]
    },
    %{
      name: :lemon_arena_league_root,
      env_var: "LEMON_ARENA_LEAGUE_ROOT",
      aliases: [],
      type: :string,
      default: nil,
      doc:
        "Root directory under which each arena domain's league dir defaults to `<domain>_league`; must be absolute for the production sim UI.",
      secret?: false,
      required?: false,
      area: :arena,
      apps: [:lemon_sim_ui]
    },
    %{
      name: :lemon_arena_poker_enabled,
      env_var: "LEMON_ARENA_POKER_ENABLED",
      aliases: [],
      type: :boolean,
      default: true,
      doc: "Whether the poker arena is enabled (only checked once MODELS is set).",
      secret?: false,
      required?: false,
      area: :arena,
      apps: [:lemon_sim_ui]
    },
    %{
      name: :lemon_arena_poker_game_delay_ms,
      env_var: "LEMON_ARENA_POKER_GAME_DELAY_MS",
      aliases: [],
      type: :integer,
      default: nil,
      doc: "Delay between games (ms) for the poker arena.",
      secret?: false,
      required?: false,
      area: :arena,
      apps: [:lemon_sim_ui]
    },
    %{
      name: :lemon_arena_poker_league_dir,
      env_var: "LEMON_ARENA_POKER_LEAGUE_DIR",
      aliases: [],
      type: :string,
      default: nil,
      doc: "League standings directory for the poker arena.",
      secret?: false,
      required?: false,
      area: :arena,
      apps: [:lemon_sim_ui]
    },
    %{
      name: :lemon_arena_poker_models,
      env_var: "LEMON_ARENA_POKER_MODELS",
      aliases: [],
      type: :list,
      default: [],
      doc: "Comma-separated provider:model specs enabling the poker arena.",
      secret?: false,
      required?: false,
      area: :arena,
      apps: [:lemon_sim_ui]
    },
    %{
      name: :lemon_arena_poker_player_count,
      env_var: "LEMON_ARENA_POKER_PLAYER_COUNT",
      aliases: [],
      type: :integer,
      default: nil,
      doc: "Player count for the poker arena.",
      secret?: false,
      required?: false,
      area: :arena,
      apps: [:lemon_sim_ui]
    },
    %{
      name: :lemon_arena_space_station_enabled,
      env_var: "LEMON_ARENA_SPACE_STATION_ENABLED",
      aliases: [],
      type: :boolean,
      default: true,
      doc: "Whether the space_station arena is enabled (only checked once MODELS is set).",
      secret?: false,
      required?: false,
      area: :arena,
      apps: [:lemon_sim_ui]
    },
    %{
      name: :lemon_arena_space_station_game_delay_ms,
      env_var: "LEMON_ARENA_SPACE_STATION_GAME_DELAY_MS",
      aliases: [],
      type: :integer,
      default: nil,
      doc: "Delay between games (ms) for the space_station arena.",
      secret?: false,
      required?: false,
      area: :arena,
      apps: [:lemon_sim_ui]
    },
    %{
      name: :lemon_arena_space_station_league_dir,
      env_var: "LEMON_ARENA_SPACE_STATION_LEAGUE_DIR",
      aliases: [],
      type: :string,
      default: nil,
      doc: "League standings directory for the space_station arena.",
      secret?: false,
      required?: false,
      area: :arena,
      apps: [:lemon_sim_ui]
    },
    %{
      name: :lemon_arena_space_station_models,
      env_var: "LEMON_ARENA_SPACE_STATION_MODELS",
      aliases: [],
      type: :list,
      default: [],
      doc: "Comma-separated provider:model specs enabling the space_station arena.",
      secret?: false,
      required?: false,
      area: :arena,
      apps: [:lemon_sim_ui]
    },
    %{
      name: :lemon_arena_space_station_player_count,
      env_var: "LEMON_ARENA_SPACE_STATION_PLAYER_COUNT",
      aliases: [],
      type: :integer,
      default: nil,
      doc: "Player count for the space_station arena.",
      secret?: false,
      required?: false,
      area: :arena,
      apps: [:lemon_sim_ui]
    },
    %{
      name: :lemon_arena_stock_market_enabled,
      env_var: "LEMON_ARENA_STOCK_MARKET_ENABLED",
      aliases: [],
      type: :boolean,
      default: true,
      doc: "Whether the stock_market arena is enabled (only checked once MODELS is set).",
      secret?: false,
      required?: false,
      area: :arena,
      apps: [:lemon_sim_ui]
    },
    %{
      name: :lemon_arena_stock_market_game_delay_ms,
      env_var: "LEMON_ARENA_STOCK_MARKET_GAME_DELAY_MS",
      aliases: [],
      type: :integer,
      default: nil,
      doc: "Delay between games (ms) for the stock_market arena.",
      secret?: false,
      required?: false,
      area: :arena,
      apps: [:lemon_sim_ui]
    },
    %{
      name: :lemon_arena_stock_market_league_dir,
      env_var: "LEMON_ARENA_STOCK_MARKET_LEAGUE_DIR",
      aliases: [],
      type: :string,
      default: nil,
      doc: "League standings directory for the stock_market arena.",
      secret?: false,
      required?: false,
      area: :arena,
      apps: [:lemon_sim_ui]
    },
    %{
      name: :lemon_arena_stock_market_models,
      env_var: "LEMON_ARENA_STOCK_MARKET_MODELS",
      aliases: [],
      type: :list,
      default: [],
      doc: "Comma-separated provider:model specs enabling the stock_market arena.",
      secret?: false,
      required?: false,
      area: :arena,
      apps: [:lemon_sim_ui]
    },
    %{
      name: :lemon_arena_stock_market_player_count,
      env_var: "LEMON_ARENA_STOCK_MARKET_PLAYER_COUNT",
      aliases: [],
      type: :integer,
      default: nil,
      doc: "Player count for the stock_market arena.",
      secret?: false,
      required?: false,
      area: :arena,
      apps: [:lemon_sim_ui]
    },
    %{
      name: :lemon_arena_survivor_enabled,
      env_var: "LEMON_ARENA_SURVIVOR_ENABLED",
      aliases: [],
      type: :boolean,
      default: true,
      doc: "Whether the survivor arena is enabled (only checked once MODELS is set).",
      secret?: false,
      required?: false,
      area: :arena,
      apps: [:lemon_sim_ui]
    },
    %{
      name: :lemon_arena_survivor_game_delay_ms,
      env_var: "LEMON_ARENA_SURVIVOR_GAME_DELAY_MS",
      aliases: [],
      type: :integer,
      default: nil,
      doc: "Delay between games (ms) for the survivor arena.",
      secret?: false,
      required?: false,
      area: :arena,
      apps: [:lemon_sim_ui]
    },
    %{
      name: :lemon_arena_survivor_league_dir,
      env_var: "LEMON_ARENA_SURVIVOR_LEAGUE_DIR",
      aliases: [],
      type: :string,
      default: nil,
      doc: "League standings directory for the survivor arena.",
      secret?: false,
      required?: false,
      area: :arena,
      apps: [:lemon_sim_ui]
    },
    %{
      name: :lemon_arena_survivor_models,
      env_var: "LEMON_ARENA_SURVIVOR_MODELS",
      aliases: [],
      type: :list,
      default: [],
      doc: "Comma-separated provider:model specs enabling the survivor arena.",
      secret?: false,
      required?: false,
      area: :arena,
      apps: [:lemon_sim_ui]
    },
    %{
      name: :lemon_arena_survivor_player_count,
      env_var: "LEMON_ARENA_SURVIVOR_PLAYER_COUNT",
      aliases: [],
      type: :integer,
      default: nil,
      doc: "Player count for the survivor arena.",
      secret?: false,
      required?: false,
      area: :arena,
      apps: [:lemon_sim_ui]
    },
    %{
      name: :lemon_arena_werewolf_enabled,
      env_var: "LEMON_ARENA_WEREWOLF_ENABLED",
      aliases: ["WEREWOLF_ARENA_ENABLED"],
      type: :boolean,
      default: true,
      doc: "Whether the werewolf arena is enabled (only checked once MODELS is set).",
      secret?: false,
      required?: false,
      area: :arena,
      apps: [:lemon_sim_ui]
    },
    %{
      name: :lemon_arena_werewolf_game_delay_ms,
      env_var: "LEMON_ARENA_WEREWOLF_GAME_DELAY_MS",
      aliases: ["WEREWOLF_ARENA_GAME_DELAY_MS"],
      type: :integer,
      default: nil,
      doc: "Delay between games (ms) for the werewolf arena.",
      secret?: false,
      required?: false,
      area: :arena,
      apps: [:lemon_sim_ui]
    },
    %{
      name: :lemon_arena_werewolf_league_dir,
      env_var: "LEMON_ARENA_WEREWOLF_LEAGUE_DIR",
      aliases: ["WEREWOLF_LEAGUE_DIR"],
      type: :string,
      default: nil,
      doc: "League standings directory for the werewolf arena.",
      secret?: false,
      required?: false,
      area: :arena,
      apps: [:lemon_sim_ui]
    },
    %{
      name: :lemon_arena_werewolf_models,
      env_var: "LEMON_ARENA_WEREWOLF_MODELS",
      aliases: ["WEREWOLF_ARENA_MODELS"],
      type: :list,
      default: [],
      doc: "Comma-separated provider:model specs enabling the werewolf arena.",
      secret?: false,
      required?: false,
      area: :arena,
      apps: [:lemon_sim_ui]
    },
    %{
      name: :lemon_arena_werewolf_player_count,
      env_var: "LEMON_ARENA_WEREWOLF_PLAYER_COUNT",
      aliases: ["WEREWOLF_ARENA_PLAYER_COUNT"],
      type: :integer,
      default: nil,
      doc: "Player count for the werewolf arena.",
      secret?: false,
      required?: false,
      area: :arena,
      apps: [:lemon_sim_ui]
    },
    %{
      name: :lemon_goal_judge_model,
      env_var: "LEMON_GOAL_JUDGE_MODEL",
      aliases: [],
      type: :string,
      default: nil,
      doc: "Model id used to judge automation goal completion.",
      secret?: false,
      required?: false,
      area: :arena,
      apps: [:lemon_automation]
    },
    %{
      name: :lemon_sim_auto_loop,
      env_var: "LEMON_SIM_AUTO_LOOP",
      aliases: [],
      type: :boolean,
      default: false,
      doc: "Whether the werewolf auto-loop starts automatically on boot.",
      secret?: false,
      required?: false,
      area: :arena,
      apps: [:lemon_sim_ui]
    },
    %{
      name: :lemon_sim_werewolf_players,
      env_var: "LEMON_SIM_WEREWOLF_PLAYERS",
      aliases: [],
      type: :integer,
      default: 6,
      doc: "Player count for the werewolf auto-loop.",
      secret?: false,
      required?: false,
      area: :arena,
      apps: [:lemon_sim_ui]
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
      default: 18800,
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
      name: :lemon_agent_profiles_cwd,
      env_var: "LEMON_AGENT_PROFILES_CWD",
      aliases: [],
      type: :string,
      default: nil,
      doc: "Working directory override used to resolve router agent profiles.",
      secret?: false,
      required?: false,
      area: :endpoints,
      apps: [:lemon_router]
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
      name: :lemon_gateway_health_port,
      env_var: "LEMON_GATEWAY_HEALTH_PORT",
      aliases: [],
      type: :integer,
      default: nil,
      doc: "Port the gateway health-check endpoint listens on.",
      secret?: false,
      required?: false,
      area: :endpoints,
      apps: [:lemon_gateway]
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
    },
    %{
      name: :lemon_router_health_port,
      env_var: "LEMON_ROUTER_HEALTH_PORT",
      aliases: [],
      type: :integer,
      default: nil,
      doc: "Port the router health-check endpoint listens on.",
      secret?: false,
      required?: false,
      area: :endpoints,
      apps: [:lemon_router]
    },
    %{
      name: :lemon_sim_ui_access_token,
      env_var: "LEMON_SIM_UI_ACCESS_TOKEN",
      aliases: [],
      type: :string,
      default: nil,
      doc: "Admin token; required with at least 32 bytes for a production Sim UI endpoint.",
      secret?: true,
      required?: false,
      area: :endpoints,
      apps: [:lemon_sim_ui]
    },
    %{
      name: :lemon_sim_ui_bind_ip,
      env_var: "LEMON_SIM_UI_BIND_IP",
      aliases: [],
      type: :string,
      default: "127.0.0.1",
      doc: "Bind IP address for the LemonSimUi dev endpoint.",
      secret?: false,
      required?: false,
      area: :endpoints,
      apps: [:lemon_sim_ui]
    },
    %{
      name: :lemon_sim_ui_host,
      env_var: "LEMON_SIM_UI_HOST",
      aliases: [],
      type: :string,
      default: "localhost",
      doc: "Public hostname for the LemonSimUi prod endpoint; explicit in production.",
      secret?: false,
      required?: false,
      area: :endpoints,
      apps: [:lemon_sim_ui]
    },
    %{
      name: :lemon_sim_ui_port,
      env_var: "LEMON_SIM_UI_PORT",
      aliases: [],
      type: :integer,
      default: 4090,
      doc: "Port LemonSimUi listens on.",
      secret?: false,
      required?: false,
      area: :endpoints,
      apps: [:lemon_sim_ui]
    },
    %{
      name: :lemon_sim_ui_url_scheme,
      env_var: "LEMON_SIM_UI_URL_SCHEME",
      aliases: [],
      type: :string,
      default: "https",
      doc: "Public URL scheme for generated LemonSimUi links (http or https).",
      secret?: false,
      required?: false,
      area: :endpoints,
      apps: [:lemon_sim_ui]
    },
    %{
      name: :lemon_sim_ui_url_port,
      env_var: "LEMON_SIM_UI_URL_PORT",
      aliases: [],
      type: :integer,
      default: 443,
      doc: "Public URL port for generated LemonSimUi links.",
      secret?: false,
      required?: false,
      area: :endpoints,
      apps: [:lemon_sim_ui]
    },
    %{
      name: :lemon_sim_ui_public_vending_launcher,
      env_var: "LEMON_SIM_UI_PUBLIC_VENDING_LAUNCHER",
      aliases: [],
      type: :boolean,
      default: false,
      doc: "Whether the public VendingBench launcher page is exposed.",
      secret?: false,
      required?: false,
      area: :endpoints,
      apps: [:lemon_sim_ui]
    },
    %{
      name: :lemon_sim_ui_secret_key_base,
      env_var: "LEMON_SIM_UI_SECRET_KEY_BASE",
      aliases: [],
      type: :string,
      default: nil,
      doc:
        "Phoenix secret_key_base; required with at least 64 bytes for a production Sim UI endpoint.",
      secret?: true,
      required?: false,
      area: :endpoints,
      apps: [:lemon_sim_ui]
    },
    %{
      name: :lemon_sim_ui_suite_roots,
      env_var: "LEMON_SIM_UI_SUITE_ROOTS",
      aliases: [],
      type: :list,
      default: [],
      doc: "Colon-separated extra suite root directories for LemonSimUi.",
      secret?: false,
      required?: false,
      area: :endpoints,
      apps: [:lemon_sim_ui]
    },
    %{
      name: :lemon_web_access_token,
      env_var: "LEMON_WEB_ACCESS_TOKEN",
      aliases: [],
      type: :string,
      default: nil,
      doc: "Bearer token required to access the LemonWeb HTTP API.",
      secret?: true,
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
    },
    %{
      name: :phx_server,
      env_var: "PHX_SERVER",
      aliases: [],
      type: :boolean,
      default: false,
      doc:
        "Standard Phoenix flag to start the HTTP server in a release (ecosystem-standard name).",
      secret?: false,
      required?: false,
      area: :endpoints,
      apps: [:lemon_web, :lemon_sim_ui]
    },
    %{
      name: :sentry_dsn,
      env_var: "SENTRY_DSN",
      aliases: [],
      type: :string,
      default: nil,
      doc: "Sentry DSN; error reporting is dormant unless this is set.",
      secret?: true,
      required?: false,
      area: :error_reporting,
      apps: [:lemon_core]
    },
    %{
      name: :sentry_environment,
      env_var: "SENTRY_ENVIRONMENT",
      aliases: [],
      type: :string,
      default: nil,
      doc: "Sentry environment name override (falls back to LEMON_ENV, then Mix env).",
      secret?: false,
      required?: false,
      area: :error_reporting,
      apps: [:lemon_core]
    },
    %{
      name: :lemon_eval_api_key,
      env_var: "LEMON_EVAL_API_KEY",
      aliases: ["INTEGRATION_API_KEY", "ANTHROPIC_API_KEY"],
      type: :string,
      default: nil,
      doc: "Live-eval provider API key.",
      secret?: true,
      required?: false,
      area: :evals_live,
      apps: [:lemon_evals]
    },
    %{
      name: :lemon_eval_api_key_secret,
      env_var: "LEMON_EVAL_API_KEY_SECRET",
      aliases: ["INTEGRATION_API_KEY_SECRET"],
      type: :string,
      default: nil,
      doc: "Secrets-store key name resolving to the live-eval API key.",
      secret?: true,
      required?: false,
      area: :evals_live,
      apps: [:lemon_evals]
    },
    %{
      name: :lemon_eval_api_type,
      env_var: "LEMON_EVAL_API_TYPE",
      aliases: ["INTEGRATION_API_TYPE"],
      type: :string,
      default: nil,
      doc: "Live-eval `Ai.Types.Model.api` atom override (default: anthropic_messages).",
      secret?: false,
      required?: false,
      area: :evals_live,
      apps: [:lemon_evals]
    },
    %{
      name: :lemon_eval_base_url,
      env_var: "LEMON_EVAL_BASE_URL",
      aliases: ["INTEGRATION_BASE_URL"],
      type: :string,
      default: nil,
      doc: "Live-eval API base URL override.",
      secret?: false,
      required?: false,
      area: :evals_live,
      apps: [:lemon_evals]
    },
    %{
      name: :lemon_eval_model,
      env_var: "LEMON_EVAL_MODEL",
      aliases: ["INTEGRATION_MODEL"],
      type: :string,
      default: nil,
      doc: "Live-eval model id (default: kimi-for-coding).",
      secret?: false,
      required?: false,
      area: :evals_live,
      apps: [:lemon_evals]
    },
    %{
      name: :lemon_eval_provider,
      env_var: "LEMON_EVAL_PROVIDER",
      aliases: ["INTEGRATION_PROVIDER"],
      type: :string,
      default: nil,
      doc: "Live-eval provider atom override (default: kimi).",
      secret?: false,
      required?: false,
      area: :evals_live,
      apps: [:lemon_evals]
    },
    %{
      name: :discord_bot_token,
      env_var: "DISCORD_BOT_TOKEN",
      aliases: [],
      type: :string,
      default: nil,
      doc: "Discord bot token (ecosystem-standard name).",
      secret?: true,
      required?: false,
      area: :gateway,
      apps: [:lemon_channels]
    },
    %{
      name: :farcaster_account_id,
      env_var: "FARCASTER_ACCOUNT_ID",
      aliases: [],
      type: :string,
      default: nil,
      doc: "Farcaster account id used by the Farcaster transport.",
      secret?: false,
      required?: false,
      area: :gateway,
      apps: [:lemon_gateway]
    },
    %{
      name: :farcaster_api_key,
      env_var: "FARCASTER_API_KEY",
      aliases: [],
      type: :string,
      default: nil,
      doc: "Farcaster (Neynar) API key.",
      secret?: true,
      required?: false,
      area: :gateway,
      apps: [:lemon_gateway]
    },
    %{
      name: :farcaster_hub_validate_url,
      env_var: "FARCASTER_HUB_VALIDATE_URL",
      aliases: [],
      type: :string,
      default: nil,
      doc: "Farcaster hub URL used to validate cast/frame messages.",
      secret?: false,
      required?: false,
      area: :gateway,
      apps: [:lemon_gateway]
    },
    %{
      name: :farcaster_signer_uuid,
      env_var: "FARCASTER_SIGNER_UUID",
      aliases: [],
      type: :string,
      default: nil,
      doc: "Farcaster signer UUID used to post casts.",
      secret?: true,
      required?: false,
      area: :gateway,
      apps: [:lemon_gateway]
    },
    %{
      name: :farcaster_state_secret,
      env_var: "FARCASTER_STATE_SECRET",
      aliases: [],
      type: :string,
      default: nil,
      doc: "Secret used to sign Farcaster frame state tokens.",
      secret?: true,
      required?: false,
      area: :gateway,
      apps: [:lemon_gateway]
    },
    %{
      name: :lemon_gateway_auto_resume,
      env_var: "LEMON_GATEWAY_AUTO_RESUME",
      aliases: [],
      type: :boolean,
      default: false,
      doc: "Whether the gateway auto-resumes interrupted runs on boot.",
      secret?: false,
      required?: false,
      area: :gateway,
      apps: [:lemon_core, :lemon_gateway]
    },
    %{
      name: :lemon_gateway_default_cwd,
      env_var: "LEMON_GATEWAY_DEFAULT_CWD",
      aliases: [],
      type: :string,
      default: nil,
      doc: "Default working directory for gateway-initiated runs.",
      secret?: false,
      required?: false,
      area: :gateway,
      apps: [:lemon_core, :lemon_gateway]
    },
    %{
      name: :lemon_gateway_default_engine,
      env_var: "LEMON_GATEWAY_DEFAULT_ENGINE",
      aliases: [],
      type: :string,
      default: "lemon",
      doc: "Default coding-agent engine used for gateway-initiated runs.",
      secret?: false,
      required?: false,
      area: :gateway,
      apps: [:lemon_core, :lemon_gateway]
    },
    %{
      name: :lemon_gateway_enable_discord,
      env_var: "LEMON_GATEWAY_ENABLE_DISCORD",
      aliases: [],
      type: :boolean,
      default: false,
      doc: "Whether the Discord transport is enabled.",
      secret?: false,
      required?: false,
      area: :gateway,
      apps: [:lemon_core, :lemon_channels]
    },
    %{
      name: :lemon_gateway_enable_email,
      env_var: "LEMON_GATEWAY_ENABLE_EMAIL",
      aliases: [],
      type: :boolean,
      default: false,
      doc: "Whether the email transport is enabled.",
      secret?: false,
      required?: false,
      area: :gateway,
      apps: [:lemon_core, :lemon_gateway]
    },
    %{
      name: :lemon_gateway_enable_farcaster,
      env_var: "LEMON_GATEWAY_ENABLE_FARCASTER",
      aliases: [],
      type: :boolean,
      default: false,
      doc: "Whether the Farcaster transport is enabled.",
      secret?: false,
      required?: false,
      area: :gateway,
      apps: [:lemon_core, :lemon_gateway]
    },
    %{
      name: :lemon_gateway_enable_telegram,
      env_var: "LEMON_GATEWAY_ENABLE_TELEGRAM",
      aliases: [],
      type: :boolean,
      default: false,
      doc: "Whether the Telegram transport is enabled.",
      secret?: false,
      required?: false,
      area: :gateway,
      apps: [:lemon_core, :lemon_channels]
    },
    %{
      name: :lemon_gateway_enable_webhook,
      env_var: "LEMON_GATEWAY_ENABLE_WEBHOOK",
      aliases: [],
      type: :boolean,
      default: false,
      doc: "Whether the generic webhook transport is enabled.",
      secret?: false,
      required?: false,
      area: :gateway,
      apps: [:lemon_core, :lemon_gateway]
    },
    %{
      name: :lemon_gateway_enable_xmtp,
      env_var: "LEMON_GATEWAY_ENABLE_XMTP",
      aliases: [],
      type: :boolean,
      default: false,
      doc: "Whether the XMTP transport is enabled.",
      secret?: false,
      required?: false,
      area: :gateway,
      apps: [:lemon_core, :lemon_channels]
    },
    %{
      name: :lemon_gateway_engine_lock_timeout_ms,
      env_var: "LEMON_GATEWAY_ENGINE_LOCK_TIMEOUT_MS",
      aliases: [],
      type: :integer,
      default: 60000,
      doc: "Engine lock acquisition timeout, in milliseconds.",
      secret?: false,
      required?: false,
      area: :gateway,
      apps: [:lemon_core, :lemon_gateway]
    },
    %{
      name: :lemon_gateway_max_concurrent_runs,
      env_var: "LEMON_GATEWAY_MAX_CONCURRENT_RUNS",
      aliases: [],
      type: :integer,
      default: 2,
      doc: "Maximum concurrent agent runs the gateway will schedule.",
      secret?: false,
      required?: false,
      area: :gateway,
      apps: [:lemon_core, :lemon_gateway]
    },
    %{
      name: :lemon_gateway_require_engine_lock,
      env_var: "LEMON_GATEWAY_REQUIRE_ENGINE_LOCK",
      aliases: [],
      type: :boolean,
      default: true,
      doc: "Whether an engine lock is required before starting a gateway run.",
      secret?: false,
      required?: false,
      area: :gateway,
      apps: [:lemon_core, :lemon_gateway]
    },
    %{
      name: :lemon_lock_dir,
      env_var: "LEMON_LOCK_DIR",
      aliases: [],
      type: :string,
      default: nil,
      doc: "Directory used for gateway/channel file locks.",
      secret?: false,
      required?: false,
      area: :gateway,
      apps: [:lemon_channels]
    },
    %{
      name: :lemon_telegram_compaction_context_window,
      env_var: "LEMON_TELEGRAM_COMPACTION_CONTEXT_WINDOW",
      aliases: [],
      type: :integer,
      default: 400_000,
      doc: "Context window size (tokens) used for Telegram compaction triggers.",
      secret?: false,
      required?: false,
      area: :gateway,
      apps: [:lemon_core, :lemon_channels]
    },
    %{
      name: :lemon_telegram_compaction_enabled,
      env_var: "LEMON_TELEGRAM_COMPACTION_ENABLED",
      aliases: [],
      type: :boolean,
      default: true,
      doc: "Whether Telegram session transcripts are auto-compacted.",
      secret?: false,
      required?: false,
      area: :gateway,
      apps: [:lemon_core, :lemon_channels]
    },
    %{
      name: :lemon_telegram_compaction_reserve_tokens,
      env_var: "LEMON_TELEGRAM_COMPACTION_RESERVE_TOKENS",
      aliases: [],
      type: :integer,
      default: 16384,
      doc: "Token budget reserved during Telegram session compaction.",
      secret?: false,
      required?: false,
      area: :gateway,
      apps: [:lemon_core, :lemon_channels]
    },
    %{
      name: :lemon_telegram_compaction_trigger_ratio,
      env_var: "LEMON_TELEGRAM_COMPACTION_TRIGGER_RATIO",
      aliases: [],
      type: :float,
      default: 0.9,
      doc: "Context-window fill ratio that triggers Telegram compaction.",
      secret?: false,
      required?: false,
      area: :gateway,
      apps: [:lemon_core, :lemon_channels]
    },
    %{
      name: :lemon_telegram_poller_lock_stale_ms,
      env_var: "LEMON_TELEGRAM_POLLER_LOCK_STALE_MS",
      aliases: [],
      type: :integer,
      default: nil,
      doc: "Age (ms) after which a Telegram poller lock is considered stale and reclaimed.",
      secret?: false,
      required?: false,
      area: :gateway,
      apps: [:lemon_channels]
    },
    %{
      name: :lemon_sms_inbox_ttl_ms,
      env_var: "LEMON_SMS_INBOX_TTL_MS",
      aliases: [],
      type: :integer,
      default: nil,
      doc: "TTL (ms) for deduplicated inbound SMS message tracking.",
      secret?: false,
      required?: false,
      area: :gateway_sms,
      apps: [:lemon_gateway]
    },
    %{
      name: :lemon_sms_webhook_bind,
      env_var: "LEMON_SMS_WEBHOOK_BIND",
      aliases: [],
      type: :string,
      default: nil,
      doc: "Bind address for the SMS webhook server.",
      secret?: false,
      required?: false,
      area: :gateway_sms,
      apps: [:lemon_gateway]
    },
    %{
      name: :lemon_sms_webhook_enabled,
      env_var: "LEMON_SMS_WEBHOOK_ENABLED",
      aliases: [],
      type: :boolean,
      default: nil,
      doc: "Whether the inbound SMS webhook server is enabled.",
      secret?: false,
      required?: false,
      area: :gateway_sms,
      apps: [:lemon_gateway]
    },
    %{
      name: :lemon_sms_webhook_port,
      env_var: "LEMON_SMS_WEBHOOK_PORT",
      aliases: [],
      type: :integer,
      default: nil,
      doc: "Port the SMS webhook server listens on.",
      secret?: false,
      required?: false,
      area: :gateway_sms,
      apps: [:lemon_gateway]
    },
    %{
      name: :twilio_account_sid,
      env_var: "TWILIO_ACCOUNT_SID",
      aliases: [],
      type: :string,
      default: nil,
      doc: "Twilio account SID (ecosystem-standard name, grandfathered).",
      secret?: true,
      required?: false,
      area: :gateway_sms,
      apps: [:lemon_gateway]
    },
    %{
      name: :twilio_auth_token,
      env_var: "TWILIO_AUTH_TOKEN",
      aliases: [],
      type: :string,
      default: nil,
      doc: "Twilio auth token (ecosystem-standard name, grandfathered).",
      secret?: true,
      required?: false,
      area: :gateway_sms,
      apps: [:lemon_gateway]
    },
    %{
      name: :twilio_inbox_number,
      env_var: "TWILIO_INBOX_NUMBER",
      aliases: [],
      type: :string,
      default: nil,
      doc: "Twilio inbox phone number used for inbound SMS routing.",
      secret?: false,
      required?: false,
      area: :gateway_sms,
      apps: [:lemon_gateway]
    },
    %{
      name: :twilio_phone_number,
      env_var: "TWILIO_PHONE_NUMBER",
      aliases: [],
      type: :string,
      default: nil,
      doc: "Twilio sending phone number (ecosystem-standard name, grandfathered).",
      secret?: false,
      required?: false,
      area: :gateway_sms,
      apps: [:lemon_gateway]
    },
    %{
      name: :twilio_validate_webhook,
      env_var: "TWILIO_VALIDATE_WEBHOOK",
      aliases: [],
      type: :boolean,
      default: true,
      doc: "Whether inbound Twilio webhook signatures are validated.",
      secret?: false,
      required?: false,
      area: :gateway_sms,
      apps: [:lemon_gateway]
    },
    %{
      name: :twilio_webhook_url,
      env_var: "TWILIO_WEBHOOK_URL",
      aliases: [],
      type: :string,
      default: nil,
      doc: "Public URL Twilio uses to reach the SMS webhook.",
      secret?: false,
      required?: false,
      area: :gateway_sms,
      apps: [:lemon_gateway]
    },
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
      name: :voice_public_url,
      env_var: "VOICE_PUBLIC_URL",
      aliases: [],
      type: :string,
      default: nil,
      doc: "Public URL for the voice websocket endpoint (grandfathered, no LEMON_ prefix).",
      secret?: false,
      required?: false,
      area: :gateway_voice,
      apps: [:lemon_gateway]
    },
    %{
      name: :voice_recordings_dir,
      env_var: "VOICE_RECORDINGS_DIR",
      aliases: [],
      type: :string,
      default: nil,
      doc: "Directory where downloaded call recordings are stored.",
      secret?: false,
      required?: false,
      area: :gateway_voice,
      apps: [:lemon_gateway]
    },
    %{
      name: :lemon_log_compress_on_rotate,
      env_var: "LEMON_LOG_COMPRESS_ON_ROTATE",
      aliases: [],
      type: :boolean,
      default: nil,
      doc: "Whether rotated log files are gzip-compressed.",
      secret?: false,
      required?: false,
      area: :logging,
      apps: [:lemon_core]
    },
    %{
      name: :lemon_log_file,
      env_var: "LEMON_LOG_FILE",
      aliases: [],
      type: :string,
      default: nil,
      doc: "Path to the log file (nil disables file logging).",
      secret?: false,
      required?: false,
      area: :logging,
      apps: [:lemon_core]
    },
    %{
      name: :lemon_log_filesync_repeat_interval,
      env_var: "LEMON_LOG_FILESYNC_REPEAT_INTERVAL",
      aliases: [],
      type: :integer,
      default: nil,
      doc: "Log file sync interval, in milliseconds.",
      secret?: false,
      required?: false,
      area: :logging,
      apps: [:lemon_core]
    },
    %{
      name: :lemon_log_level,
      env_var: "LEMON_LOG_LEVEL",
      aliases: [],
      type: :string,
      default: nil,
      doc:
        "Global log level override (debug/info/notice/warning/error/critical/alert/emergency).",
      secret?: false,
      required?: false,
      area: :logging,
      apps: [:lemon_core]
    },
    %{
      name: :lemon_log_max_no_bytes,
      env_var: "LEMON_LOG_MAX_NO_BYTES",
      aliases: [],
      type: :integer,
      default: nil,
      doc:
        "Log file rotation size threshold, in bytes. Plain integer only -- unlike " <>
          "LEMON_WASM_DEFAULT_MEMORY_LIMIT, this one does not accept \"10MB\"-style suffixes.",
      secret?: false,
      required?: false,
      area: :logging,
      apps: [:lemon_core]
    },
    %{
      name: :lemon_log_max_no_files,
      env_var: "LEMON_LOG_MAX_NO_FILES",
      aliases: [],
      type: :integer,
      default: nil,
      doc: "Number of rotated log files retained.",
      secret?: false,
      required?: false,
      area: :logging,
      apps: [:lemon_core]
    },
    %{
      name: :home,
      env_var: "HOME",
      aliases: [],
      type: :string,
      default: nil,
      doc:
        "Standard POSIX home directory; used for default `.lemon` locations and OAuth token caches.",
      secret?: false,
      required?: false,
      area: :platform,
      apps: [:lemon_core, :ai, :coding_agent]
    },
    %{
      name: :mix_env,
      env_var: "MIX_ENV",
      aliases: [],
      type: :string,
      default: nil,
      doc: "Standard Mix environment (dev/test/prod).",
      secret?: false,
      required?: false,
      area: :platform,
      apps: [:lemon_core]
    },
    %{
      name: :release_name,
      env_var: "RELEASE_NAME",
      aliases: [],
      type: :string,
      default: nil,
      doc: "Standard Elixir release name; selects which endpoint(s) boot in a multi-app release.",
      secret?: false,
      required?: false,
      area: :platform,
      apps: [:lemon_core]
    },
    %{
      name: :release_node,
      env_var: "RELEASE_NODE",
      aliases: [],
      type: :string,
      default: nil,
      doc: "Standard Elixir release node name; presence indicates a running release (vs. `mix`).",
      secret?: false,
      required?: false,
      area: :platform,
      apps: [:lemon_core]
    },
    %{
      name: :release_vsn,
      env_var: "RELEASE_VSN",
      aliases: [],
      type: :string,
      default: nil,
      doc: "Standard Elixir release version.",
      secret?: false,
      required?: false,
      area: :platform,
      apps: [:lemon_core]
    },
    %{
      name: :shell,
      env_var: "SHELL",
      aliases: [],
      type: :string,
      default: "/bin/sh",
      doc: "Standard POSIX shell path, used as a fallback shell for the external decider.",
      secret?: false,
      required?: false,
      area: :platform,
      apps: [:lemon_sim]
    },
    %{
      name: :term,
      env_var: "TERM",
      aliases: [],
      type: :string,
      default: nil,
      doc: "Standard terminal type variable; used to detect non-interactive/dumb terminals.",
      secret?: false,
      required?: false,
      area: :platform,
      apps: [:lemon_cli]
    },
    %{
      name: :openai_base_url,
      env_var: "OPENAI_BASE_URL",
      aliases: [],
      type: :string,
      default: nil,
      doc: "OpenAI API base URL override (ecosystem-standard name).",
      secret?: false,
      required?: false,
      area: :provider,
      apps: [:ai]
    },
    %{
      name: :anthropic_api_key,
      env_var: "ANTHROPIC_API_KEY",
      aliases: [],
      type: :string,
      default: nil,
      doc: "Anthropic API key.",
      secret?: true,
      required?: false,
      area: :provider_secrets,
      apps: [:ai]
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
      name: :aws_default_region,
      env_var: "AWS_DEFAULT_REGION",
      aliases: [],
      type: :string,
      default: nil,
      doc: "AWS region fallback (ecosystem-standard AWS CLI name).",
      secret?: false,
      required?: false,
      area: :provider_secrets,
      apps: [:lemon_core]
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
      name: :aws_region,
      env_var: "AWS_REGION",
      aliases: [],
      type: :string,
      default: "us-east-1",
      doc: "AWS region for Bedrock (ecosystem-standard name).",
      secret?: false,
      required?: false,
      area: :provider_secrets,
      apps: [:lemon_core]
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
    },
    %{
      name: :aws_session_token,
      env_var: "AWS_SESSION_TOKEN",
      aliases: [],
      type: :string,
      default: nil,
      doc: "AWS temporary session token for Bedrock (ecosystem-standard name).",
      secret?: true,
      required?: false,
      area: :provider_secrets,
      apps: [:lemon_core]
    },
    %{
      name: :azure_openai_api_key,
      env_var: "AZURE_OPENAI_API_KEY",
      aliases: [],
      type: :string,
      default: nil,
      doc: "Azure OpenAI API key.",
      secret?: true,
      required?: false,
      area: :provider_secrets,
      apps: [:ai]
    },
    %{
      name: :azure_openai_api_version,
      env_var: "AZURE_OPENAI_API_VERSION",
      aliases: [],
      type: :string,
      default: nil,
      doc: "Azure OpenAI API version.",
      secret?: false,
      required?: false,
      area: :provider_secrets,
      apps: [:lemon_core]
    },
    %{
      name: :azure_openai_base_url,
      env_var: "AZURE_OPENAI_BASE_URL",
      aliases: [],
      type: :string,
      default: nil,
      doc: "Azure OpenAI resource base URL.",
      secret?: false,
      required?: false,
      area: :provider_secrets,
      apps: [:lemon_core]
    },
    %{
      name: :azure_openai_deployment_name_map,
      env_var: "AZURE_OPENAI_DEPLOYMENT_NAME_MAP",
      aliases: [],
      type: :string,
      default: nil,
      doc: "JSON map of model id to Azure OpenAI deployment name.",
      secret?: false,
      required?: false,
      area: :provider_secrets,
      apps: [:lemon_core]
    },
    %{
      name: :azure_openai_resource_name,
      env_var: "AZURE_OPENAI_RESOURCE_NAME",
      aliases: [],
      type: :string,
      default: nil,
      doc: "Azure OpenAI resource name.",
      secret?: false,
      required?: false,
      area: :provider_secrets,
      apps: [:lemon_core]
    },
    %{
      name: :chatgpt_token,
      env_var: "CHATGPT_TOKEN",
      aliases: [],
      type: :string,
      default: nil,
      doc: "ChatGPT/Codex session token (fallback for OPENAI_CODEX_API_KEY).",
      secret?: true,
      required?: false,
      area: :provider_secrets,
      apps: [:ai]
    },
    %{
      name: :gcloud_project,
      env_var: "GCLOUD_PROJECT",
      aliases: [],
      type: :string,
      default: nil,
      doc: "Google Cloud project id (gcloud CLI convention name).",
      secret?: false,
      required?: false,
      area: :provider_secrets,
      apps: [:ai, :lemon_cli, :lemon_core]
    },
    %{
      name: :gemini_api_key,
      env_var: "GEMINI_API_KEY",
      aliases: [],
      type: :string,
      default: nil,
      doc: "Gemini API key (alt name).",
      secret?: true,
      required?: false,
      area: :provider_secrets,
      apps: [:ai]
    },
    %{
      name: :github_copilot_client_id,
      env_var: "GITHUB_COPILOT_CLIENT_ID",
      aliases: [],
      type: :string,
      default: nil,
      doc: "GitHub Copilot OAuth client id override.",
      secret?: false,
      required?: false,
      area: :provider_secrets,
      apps: [:ai]
    },
    %{
      name: :google_api_key,
      env_var: "GOOGLE_API_KEY",
      aliases: [],
      type: :string,
      default: nil,
      doc: "Google Generative AI API key (alt name).",
      secret?: true,
      required?: false,
      area: :provider_secrets,
      apps: [:ai]
    },
    %{
      name: :google_application_credentials,
      env_var: "GOOGLE_APPLICATION_CREDENTIALS",
      aliases: [],
      type: :string,
      default: nil,
      doc: "Path to a Google service-account JSON credentials file (ecosystem-standard name).",
      secret?: true,
      required?: false,
      area: :provider_secrets,
      apps: [:ai, :agent_core]
    },
    %{
      name: :google_application_credentials_json,
      env_var: "GOOGLE_APPLICATION_CREDENTIALS_JSON",
      aliases: [],
      type: :string,
      default: nil,
      doc: "Inline Google service-account JSON credentials.",
      secret?: true,
      required?: false,
      area: :provider_secrets,
      apps: [:lemon_core]
    },
    %{
      name: :google_cloud_location,
      env_var: "GOOGLE_CLOUD_LOCATION",
      aliases: [],
      type: :string,
      default: nil,
      doc: "Google Cloud / Vertex AI region.",
      secret?: false,
      required?: false,
      area: :provider_secrets,
      apps: [:lemon_core]
    },
    %{
      name: :google_cloud_project,
      env_var: "GOOGLE_CLOUD_PROJECT",
      aliases: [],
      type: :string,
      default: nil,
      doc: "Google Cloud project id (ecosystem-standard name).",
      secret?: false,
      required?: false,
      area: :provider_secrets,
      apps: [:ai, :lemon_cli, :lemon_core]
    },
    %{
      name: :google_cloud_project_id,
      env_var: "GOOGLE_CLOUD_PROJECT_ID",
      aliases: [],
      type: :string,
      default: nil,
      doc: "Google Cloud project id (alt ecosystem name).",
      secret?: false,
      required?: false,
      area: :provider_secrets,
      apps: [:ai, :lemon_cli, :lemon_core]
    },
    %{
      name: :google_gemini_cli_oauth_client_id,
      env_var: "GOOGLE_GEMINI_CLI_OAUTH_CLIENT_ID",
      aliases: [],
      type: :string,
      default: nil,
      doc: "Google Gemini CLI OAuth client id override.",
      secret?: false,
      required?: false,
      area: :provider_secrets,
      apps: [:ai]
    },
    %{
      name: :google_gemini_cli_oauth_client_secret,
      env_var: "GOOGLE_GEMINI_CLI_OAUTH_CLIENT_SECRET",
      aliases: [],
      type: :string,
      default: nil,
      doc: "Google Gemini CLI OAuth client secret override.",
      secret?: true,
      required?: false,
      area: :provider_secrets,
      apps: [:ai]
    },
    %{
      name: :google_generative_ai_api_key,
      env_var: "GOOGLE_GENERATIVE_AI_API_KEY",
      aliases: [],
      type: :string,
      default: nil,
      doc: "Google Generative AI API key (primary name).",
      secret?: true,
      required?: false,
      area: :provider_secrets,
      apps: [:ai]
    },
    %{
      name: :lemon_gemini_project_id,
      env_var: "LEMON_GEMINI_PROJECT_ID",
      aliases: [],
      type: :string,
      default: nil,
      doc:
        "Lemon-specific override for the Gemini/Vertex project id, checked before the GOOGLE_CLOUD_* names.",
      secret?: false,
      required?: false,
      area: :provider_secrets,
      apps: [:ai, :lemon_cli, :lemon_core]
    },
    %{
      name: :magic_eden_api_key,
      env_var: "MAGIC_EDEN_API_KEY",
      aliases: [],
      type: :string,
      default: nil,
      doc: "Magic Eden marketplace API key.",
      secret?: true,
      required?: false,
      area: :provider_secrets,
      apps: [:lemon_tcg]
    },
    %{
      name: :mistral_api_key,
      env_var: "MISTRAL_API_KEY",
      aliases: [],
      type: :string,
      default: nil,
      doc: "Mistral API key.",
      secret?: true,
      required?: false,
      area: :provider_secrets,
      apps: [:ai]
    },
    %{
      name: :openai_api_key,
      env_var: "OPENAI_API_KEY",
      aliases: [],
      type: :string,
      default: nil,
      doc: "OpenAI API key.",
      secret?: true,
      required?: false,
      area: :provider_secrets,
      apps: [:ai]
    },
    %{
      name: :openai_codex_api_key,
      env_var: "OPENAI_CODEX_API_KEY",
      aliases: [],
      type: :string,
      default: nil,
      doc: "OpenAI Codex API key.",
      secret?: true,
      required?: false,
      area: :provider_secrets,
      apps: [:ai]
    },
    %{
      name: :openai_codex_oauth_client_id,
      env_var: "OPENAI_CODEX_OAUTH_CLIENT_ID",
      aliases: [],
      type: :string,
      default: nil,
      doc: "OpenAI Codex OAuth client id override.",
      secret?: false,
      required?: false,
      area: :provider_secrets,
      apps: [:ai]
    },
    %{
      name: :opencode_api_key,
      env_var: "OPENCODE_API_KEY",
      aliases: [],
      type: :string,
      default: nil,
      doc: "OpenCode provider API key.",
      secret?: true,
      required?: false,
      area: :provider_secrets,
      apps: [:ai]
    },
    %{
      name: :opensea_api_key,
      env_var: "OPENSEA_API_KEY",
      aliases: [],
      type: :string,
      default: nil,
      doc: "OpenSea marketplace API key.",
      secret?: true,
      required?: false,
      area: :provider_secrets,
      apps: [:lemon_tcg]
    },
    %{
      name: :pricecharting_api_token,
      env_var: "PRICECHARTING_API_TOKEN",
      aliases: [],
      type: :string,
      default: nil,
      doc: "PriceCharting API token.",
      secret?: true,
      required?: false,
      area: :provider_secrets,
      apps: [:lemon_tcg]
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
      name: :lemon_allow_restart_tool,
      env_var: "LEMON_ALLOW_RESTART_TOOL",
      aliases: [],
      type: :boolean,
      default: false,
      doc: "Whether the agent's self-restart tool is permitted to run.",
      secret?: false,
      required?: false,
      area: :runtime,
      apps: [:coding_agent]
    },
    %{
      name: :lemon_debug,
      env_var: "LEMON_DEBUG",
      aliases: [],
      type: :boolean,
      default: false,
      doc: "Global debug flag checked at a few call sites in addition to LEMON_LOG_LEVEL.",
      secret?: false,
      required?: false,
      area: :runtime,
      apps: [:lemon_core]
    },
    %{
      name: :lemon_dotenv_dir,
      env_var: "LEMON_DOTENV_DIR",
      aliases: [],
      type: :string,
      default: nil,
      doc: "Directory to load a `.env` file from at boot.",
      secret?: false,
      required?: false,
      area: :runtime,
      apps: [:lemon_core]
    },
    %{
      name: :lemon_env,
      env_var: "LEMON_ENV",
      aliases: [],
      type: :string,
      default: nil,
      doc: "Deployment environment label (used for Sentry environment tagging).",
      secret?: false,
      required?: false,
      area: :runtime,
      apps: [:lemon_core]
    },
    %{
      name: :lemon_gateway_node_cookie,
      env_var: "LEMON_GATEWAY_NODE_COOKIE",
      aliases: ["LEMON_GATEWAY_COOKIE"],
      type: :string,
      default: nil,
      doc: "Distributed Erlang cookie for the gateway node.",
      secret?: true,
      required?: false,
      area: :runtime,
      apps: [:lemon_core]
    },
    %{
      name: :lemon_gateway_node_name,
      env_var: "LEMON_GATEWAY_NODE_NAME",
      aliases: [],
      type: :string,
      default: "lemon",
      doc: "Distributed Erlang node name for the gateway.",
      secret?: false,
      required?: false,
      area: :runtime,
      apps: [:lemon_core]
    },
    %{
      name: :lemon_path,
      env_var: "LEMON_PATH",
      aliases: [],
      type: :string,
      default: nil,
      doc: "Override for the `PATH` used when locating CLI subprocess executables.",
      secret?: false,
      required?: false,
      area: :runtime,
      apps: [:lemon_core]
    },
    %{
      name: :lemon_release_channel,
      env_var: "LEMON_RELEASE_CHANNEL",
      aliases: [],
      type: :string,
      default: nil,
      doc: "Release channel label (stable/beta/etc), falls back to inferring from RELEASE_VSN.",
      secret?: false,
      required?: false,
      area: :runtime,
      apps: [:lemon_core]
    },
    %{
      name: :lemon_runtime_profile,
      env_var: "LEMON_RUNTIME_PROFILE",
      aliases: [],
      type: :string,
      default: nil,
      doc: "Named runtime profile selecting a bundle of feature defaults.",
      secret?: false,
      required?: false,
      area: :runtime,
      apps: [:lemon_core]
    },
    %{
      name: :lemon_test_allow_live_credentials,
      env_var: "LEMON_TEST_ALLOW_LIVE_CREDENTIALS",
      aliases: [],
      type: :boolean,
      default: false,
      doc: "Test-only opt-in to allow hermetic tests to use real provider credentials.",
      secret?: false,
      required?: false,
      area: :runtime,
      apps: [:lemon_core]
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
    },
    %{
      name: :lemon_store_db_path,
      env_var: "LEMON_STORE_DB_PATH",
      aliases: [],
      type: :string,
      default: nil,
      doc: "Override path for the SQLite store database file.",
      secret?: false,
      required?: false,
      area: :store,
      apps: [:lemon_core]
    },
    %{
      name: :lemon_store_path,
      env_var: "LEMON_STORE_PATH",
      aliases: [],
      type: :string,
      default: nil,
      doc:
        "Override path for the primary JSONL/SQLite data store; required and absolute for the production sim UI.",
      secret?: false,
      required?: false,
      area: :store,
      apps: [:lemon_core]
    },
    %{
      name: :evm_private_key,
      env_var: "EVM_PRIVATE_KEY",
      aliases: [],
      type: :string,
      default: nil,
      doc: "EVM wallet private key used to sign on-chain transactions.",
      secret?: true,
      required?: false,
      area: :tcg_wallet,
      apps: [:lemon_tcg]
    },
    %{
      name: :solana_keypair_file,
      env_var: "SOLANA_KEYPAIR_FILE",
      aliases: [],
      type: :string,
      default: nil,
      doc: "Path to a Solana keypair JSON file used to sign wallet transactions.",
      secret?: true,
      required?: false,
      area: :tcg_wallet,
      apps: [:lemon_tcg]
    },
    %{
      name: :solana_secret_key,
      env_var: "SOLANA_SECRET_KEY",
      aliases: [],
      type: :string,
      default: nil,
      doc: "Base58/array-encoded Solana secret key used to sign wallet transactions.",
      secret?: true,
      required?: false,
      area: :tcg_wallet,
      apps: [:lemon_tcg]
    },
    %{
      name: :lemon_docker_terminal_cpus,
      env_var: "LEMON_DOCKER_TERMINAL_CPUS",
      aliases: [],
      type: :string,
      default: nil,
      doc: "CPU limit for the Docker terminal backend container.",
      secret?: false,
      required?: false,
      area: :terminal_docker,
      apps: [:lemon_core]
    },
    %{
      name: :lemon_docker_terminal_image,
      env_var: "LEMON_DOCKER_TERMINAL_IMAGE",
      aliases: [],
      type: :string,
      default: nil,
      doc: "Docker image used for the Docker terminal backend.",
      secret?: false,
      required?: false,
      area: :terminal_docker,
      apps: [:lemon_core]
    },
    %{
      name: :lemon_docker_terminal_memory,
      env_var: "LEMON_DOCKER_TERMINAL_MEMORY",
      aliases: [],
      type: :string,
      default: nil,
      doc: "Memory limit for the Docker terminal backend container.",
      secret?: false,
      required?: false,
      area: :terminal_docker,
      apps: [:lemon_core]
    },
    %{
      name: :lemon_docker_terminal_network,
      env_var: "LEMON_DOCKER_TERMINAL_NETWORK",
      aliases: [],
      type: :string,
      default: "none",
      doc: "Docker network mode for the Docker terminal backend container.",
      secret?: false,
      required?: false,
      area: :terminal_docker,
      apps: [:lemon_core]
    },
    %{
      name: :lemon_docker_terminal_pids_limit,
      env_var: "LEMON_DOCKER_TERMINAL_PIDS_LIMIT",
      aliases: [],
      type: :string,
      default: nil,
      doc: "Process count limit for the Docker terminal backend container.",
      secret?: false,
      required?: false,
      area: :terminal_docker,
      apps: [:lemon_core]
    },
    %{
      name: :lemon_docker_terminal_read_only_rootfs,
      env_var: "LEMON_DOCKER_TERMINAL_READ_ONLY_ROOTFS",
      aliases: [],
      type: :boolean,
      default: true,
      doc: "Whether the Docker terminal backend mounts a read-only root filesystem.",
      secret?: false,
      required?: false,
      area: :terminal_docker,
      apps: [:lemon_core]
    },
    %{
      name: :lemon_docker_terminal_tmpfs_size,
      env_var: "LEMON_DOCKER_TERMINAL_TMPFS_SIZE",
      aliases: [],
      type: :string,
      default: nil,
      doc: "tmpfs size for the Docker terminal backend's writable /tmp mount.",
      secret?: false,
      required?: false,
      area: :terminal_docker,
      apps: [:lemon_core]
    },
    %{
      name: :lemon_ssh_terminal_connect_timeout,
      env_var: "LEMON_SSH_TERMINAL_CONNECT_TIMEOUT",
      aliases: [],
      type: :string,
      default: "10",
      doc: "SSH connect timeout (seconds) for the SSH terminal backend.",
      secret?: false,
      required?: false,
      area: :terminal_ssh,
      apps: [:lemon_core]
    },
    %{
      name: :lemon_ssh_terminal_identity_file,
      env_var: "LEMON_SSH_TERMINAL_IDENTITY_FILE",
      aliases: [],
      type: :string,
      default: nil,
      doc: "SSH identity (private key) file for the SSH terminal backend.",
      secret?: true,
      required?: false,
      area: :terminal_ssh,
      apps: [:lemon_core]
    },
    %{
      name: :lemon_ssh_terminal_port,
      env_var: "LEMON_SSH_TERMINAL_PORT",
      aliases: [],
      type: :string,
      default: "22",
      doc: "SSH port for the SSH terminal backend.",
      secret?: false,
      required?: false,
      area: :terminal_ssh,
      apps: [:lemon_core]
    },
    %{
      name: :lemon_ssh_terminal_strict_host_key_checking,
      env_var: "LEMON_SSH_TERMINAL_STRICT_HOST_KEY_CHECKING",
      aliases: [],
      type: :string,
      default: "yes",
      doc: "SSH StrictHostKeyChecking setting for the SSH terminal backend.",
      secret?: false,
      required?: false,
      area: :terminal_ssh,
      apps: [:lemon_core]
    },
    %{
      name: :lemon_ssh_terminal_target,
      env_var: "LEMON_SSH_TERMINAL_TARGET",
      aliases: [],
      type: :string,
      default: nil,
      doc: "SSH target (user@host) for the SSH terminal backend.",
      secret?: false,
      required?: false,
      area: :terminal_ssh,
      apps: [:lemon_core]
    },
    %{
      name: :lemon_ssh_terminal_user_known_hosts_file,
      env_var: "LEMON_SSH_TERMINAL_USER_KNOWN_HOSTS_FILE",
      aliases: [],
      type: :string,
      default: nil,
      doc: "Known-hosts file used by the SSH terminal backend.",
      secret?: false,
      required?: false,
      area: :terminal_ssh,
      apps: [:lemon_core]
    },
    %{
      name: :lemon_ssh_terminal_workdir,
      env_var: "LEMON_SSH_TERMINAL_WORKDIR",
      aliases: [],
      type: :string,
      default: nil,
      doc: "Remote working directory for the SSH terminal backend.",
      secret?: false,
      required?: false,
      area: :terminal_ssh,
      apps: [:lemon_core]
    },
    %{
      name: :lemon_wasm_auto_build,
      env_var: "LEMON_WASM_AUTO_BUILD",
      aliases: [],
      type: :boolean,
      default: true,
      doc: "Whether WASM tools are auto-built from source on load.",
      secret?: false,
      required?: false,
      area: :tools_wasm,
      apps: [:lemon_core]
    },
    %{
      name: :lemon_wasm_cache_compiled,
      env_var: "LEMON_WASM_CACHE_COMPILED",
      aliases: [],
      type: :boolean,
      default: true,
      doc: "Whether compiled WASM modules are cached on disk.",
      secret?: false,
      required?: false,
      area: :tools_wasm,
      apps: [:lemon_core]
    },
    %{
      name: :lemon_wasm_cache_dir,
      env_var: "LEMON_WASM_CACHE_DIR",
      aliases: [],
      type: :string,
      default: "",
      doc: "Directory used for the compiled WASM module cache.",
      secret?: false,
      required?: false,
      area: :tools_wasm,
      apps: [:lemon_core]
    },
    %{
      name: :lemon_wasm_default_fuel_limit,
      env_var: "LEMON_WASM_DEFAULT_FUEL_LIMIT",
      aliases: [],
      type: :integer,
      default: 10_000_000,
      doc: "Default WASM interpreter fuel (execution-step) limit.",
      secret?: false,
      required?: false,
      area: :tools_wasm,
      apps: [:lemon_core]
    },
    %{
      name: :lemon_wasm_default_memory_limit,
      env_var: "LEMON_WASM_DEFAULT_MEMORY_LIMIT",
      aliases: [],
      type: :bytes,
      default: 10_485_760,
      doc: "Default WASM tool memory limit (accepts B/KB/MB/GB suffixes).",
      secret?: false,
      required?: false,
      area: :tools_wasm,
      apps: [:lemon_core]
    },
    %{
      name: :lemon_wasm_default_timeout_ms,
      env_var: "LEMON_WASM_DEFAULT_TIMEOUT_MS",
      aliases: [],
      type: :integer,
      default: 60000,
      doc: "Default WASM tool execution timeout, in milliseconds.",
      secret?: false,
      required?: false,
      area: :tools_wasm,
      apps: [:lemon_core]
    },
    %{
      name: :lemon_wasm_enabled,
      env_var: "LEMON_WASM_ENABLED",
      aliases: [],
      type: :boolean,
      default: false,
      doc: "Whether the WASM tool runtime is enabled.",
      secret?: false,
      required?: false,
      area: :tools_wasm,
      apps: [:lemon_core]
    },
    %{
      name: :lemon_wasm_max_tool_invoke_depth,
      env_var: "LEMON_WASM_MAX_TOOL_INVOKE_DEPTH",
      aliases: [],
      type: :integer,
      default: 4,
      doc: "Maximum nested WASM tool invocation depth.",
      secret?: false,
      required?: false,
      area: :tools_wasm,
      apps: [:lemon_core]
    },
    %{
      name: :lemon_wasm_runtime_path,
      env_var: "LEMON_WASM_RUNTIME_PATH",
      aliases: [],
      type: :string,
      default: "",
      doc: "Path to the WASM runtime executable/library.",
      secret?: false,
      required?: false,
      area: :tools_wasm,
      apps: [:lemon_core]
    },
    %{
      name: :lemon_wasm_tool_paths,
      env_var: "LEMON_WASM_TOOL_PATHS",
      aliases: [],
      type: :list,
      default: [],
      doc: "Comma-separated extra directories to search for WASM tools.",
      secret?: false,
      required?: false,
      area: :tools_wasm,
      apps: [:lemon_core]
    },
    %{
      name: :lemon_auto_resize_images,
      env_var: "LEMON_AUTO_RESIZE_IMAGES",
      aliases: [],
      type: :boolean,
      default: true,
      doc: "Whether oversized images are auto-resized before being sent to a model.",
      secret?: false,
      required?: false,
      area: :tools_web,
      apps: [:lemon_core]
    },
    %{
      name: :lemon_firecrawl_api_key,
      env_var: "LEMON_FIRECRAWL_API_KEY",
      aliases: [],
      type: :string,
      default: nil,
      doc: "Firecrawl API key.",
      secret?: true,
      required?: false,
      area: :tools_web,
      apps: [:lemon_core]
    },
    %{
      name: :lemon_firecrawl_base_url,
      env_var: "LEMON_FIRECRAWL_BASE_URL",
      aliases: [],
      type: :string,
      default: "https://api.firecrawl.dev",
      doc: "Firecrawl API base URL.",
      secret?: false,
      required?: false,
      area: :tools_web,
      apps: [:lemon_core]
    },
    %{
      name: :lemon_firecrawl_enabled,
      env_var: "LEMON_FIRECRAWL_ENABLED",
      aliases: [],
      type: :boolean,
      default: nil,
      doc:
        "Whether Firecrawl is used as the webfetch backend. Tri-state (nil = undecided, " <>
          "falls through to TOML/default); recognizes \"true\"/\"1\"/\"yes\" and " <>
          "\"false\"/\"0\"/\"no\" only -- not the \"on\"/\"off\" spellings most other " <>
          "booleans in this registry accept. Resolved with bespoke logic in " <>
          "LemonCore.Config.Tools.resolve_firecrawl/1, not the standard :boolean cast.",
      secret?: false,
      required?: false,
      area: :tools_web,
      apps: [:lemon_core]
    },
    %{
      name: :lemon_perplexity_api_key,
      env_var: "LEMON_PERPLEXITY_API_KEY",
      aliases: [],
      type: :string,
      default: nil,
      doc: "Perplexity API key used by the web search provider.",
      secret?: true,
      required?: false,
      area: :tools_web,
      apps: [:lemon_core]
    },
    %{
      name: :lemon_perplexity_base_url,
      env_var: "LEMON_PERPLEXITY_BASE_URL",
      aliases: [],
      type: :string,
      default: nil,
      doc: "Perplexity API base URL override.",
      secret?: false,
      required?: false,
      area: :tools_web,
      apps: [:lemon_core]
    },
    %{
      name: :lemon_perplexity_model,
      env_var: "LEMON_PERPLEXITY_MODEL",
      aliases: [],
      type: :string,
      default: "perplexity/sonar-pro",
      doc: "Perplexity model id used for web search.",
      secret?: false,
      required?: false,
      area: :tools_web,
      apps: [:lemon_core]
    },
    %{
      name: :lemon_web_cache_max_entries,
      env_var: "LEMON_WEB_CACHE_MAX_ENTRIES",
      aliases: [],
      type: :integer,
      default: 100,
      doc: "Maximum entries retained in the web cache.",
      secret?: false,
      required?: false,
      area: :tools_web,
      apps: [:lemon_core, :coding_agent]
    },
    %{
      name: :lemon_web_cache_path,
      env_var: "LEMON_WEB_CACHE_PATH",
      aliases: [],
      type: :string,
      default: nil,
      doc: "Path override for the persistent web cache file.",
      secret?: false,
      required?: false,
      area: :tools_web,
      apps: [:lemon_core, :coding_agent]
    },
    %{
      name: :lemon_web_cache_persistent,
      env_var: "LEMON_WEB_CACHE_PERSISTENT",
      aliases: [],
      type: :boolean,
      default: true,
      doc: "Whether the webfetch/websearch cache persists to disk.",
      secret?: false,
      required?: false,
      area: :tools_web,
      apps: [:lemon_core, :coding_agent]
    },
    %{
      name: :lemon_web_fetch_allow_private_network,
      env_var: "LEMON_WEB_FETCH_ALLOW_PRIVATE_NETWORK",
      aliases: [],
      type: :boolean,
      default: false,
      doc: "Whether webfetch is allowed to reach private/internal network addresses.",
      secret?: false,
      required?: false,
      area: :tools_web,
      apps: [:lemon_core]
    },
    %{
      name: :lemon_web_fetch_allowed_hostnames,
      env_var: "LEMON_WEB_FETCH_ALLOWED_HOSTNAMES",
      aliases: [],
      type: :list,
      default: [],
      doc: "Comma-separated hostname allowlist for webfetch.",
      secret?: false,
      required?: false,
      area: :tools_web,
      apps: [:lemon_core]
    },
    %{
      name: :lemon_web_fetch_cache_ttl,
      env_var: "LEMON_WEB_FETCH_CACHE_TTL",
      aliases: [],
      type: :integer,
      default: 15,
      doc: "Webfetch result cache TTL, in minutes.",
      secret?: false,
      required?: false,
      area: :tools_web,
      apps: [:lemon_core]
    },
    %{
      name: :lemon_web_fetch_enabled,
      env_var: "LEMON_WEB_FETCH_ENABLED",
      aliases: [],
      type: :boolean,
      default: true,
      doc: "Whether the webfetch tool is enabled.",
      secret?: false,
      required?: false,
      area: :tools_web,
      apps: [:lemon_core]
    },
    %{
      name: :lemon_web_fetch_max_chars,
      env_var: "LEMON_WEB_FETCH_MAX_CHARS",
      aliases: [],
      type: :integer,
      default: 50000,
      doc: "Maximum characters of fetched page content returned to the model.",
      secret?: false,
      required?: false,
      area: :tools_web,
      apps: [:lemon_core]
    },
    %{
      name: :lemon_web_fetch_max_redirects,
      env_var: "LEMON_WEB_FETCH_MAX_REDIRECTS",
      aliases: [],
      type: :integer,
      default: 3,
      doc: "Maximum HTTP redirects followed by webfetch.",
      secret?: false,
      required?: false,
      area: :tools_web,
      apps: [:lemon_core]
    },
    %{
      name: :lemon_web_fetch_readability,
      env_var: "LEMON_WEB_FETCH_READABILITY",
      aliases: [],
      type: :boolean,
      default: true,
      doc: "Whether webfetch runs readability extraction on HTML pages.",
      secret?: false,
      required?: false,
      area: :tools_web,
      apps: [:lemon_core]
    },
    %{
      name: :lemon_web_fetch_timeout,
      env_var: "LEMON_WEB_FETCH_TIMEOUT",
      aliases: [],
      type: :integer,
      default: 30,
      doc: "Webfetch request timeout, in seconds.",
      secret?: false,
      required?: false,
      area: :tools_web,
      apps: [:lemon_core]
    },
    %{
      name: :lemon_web_fetch_user_agent,
      env_var: "LEMON_WEB_FETCH_USER_AGENT",
      aliases: [],
      type: :string,
      default:
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_7_2) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36",
      doc: "User-Agent header sent by webfetch.",
      secret?: false,
      required?: false,
      area: :tools_web,
      apps: [:lemon_core]
    },
    %{
      name: :lemon_web_search_api_key,
      env_var: "LEMON_WEB_SEARCH_API_KEY",
      aliases: [],
      type: :string,
      default: nil,
      doc: "API key for the configured web search provider.",
      secret?: true,
      required?: false,
      area: :tools_web,
      apps: [:lemon_core]
    },
    %{
      name: :lemon_web_search_cache_ttl,
      env_var: "LEMON_WEB_SEARCH_CACHE_TTL",
      aliases: [],
      type: :integer,
      default: 15,
      doc: "Web search result cache TTL, in minutes.",
      secret?: false,
      required?: false,
      area: :tools_web,
      apps: [:lemon_core]
    },
    %{
      name: :lemon_web_search_enabled,
      env_var: "LEMON_WEB_SEARCH_ENABLED",
      aliases: [],
      type: :boolean,
      default: true,
      doc: "Whether the web search tool is enabled.",
      secret?: false,
      required?: false,
      area: :tools_web,
      apps: [:lemon_core]
    },
    %{
      name: :lemon_web_search_failover_enabled,
      env_var: "LEMON_WEB_SEARCH_FAILOVER_ENABLED",
      aliases: [],
      type: :boolean,
      default: true,
      doc: "Whether web search falls over to a secondary provider on failure.",
      secret?: false,
      required?: false,
      area: :tools_web,
      apps: [:lemon_core]
    },
    %{
      name: :lemon_web_search_failover_provider,
      env_var: "LEMON_WEB_SEARCH_FAILOVER_PROVIDER",
      aliases: [],
      type: :string,
      default: nil,
      doc: "Secondary web search provider id used on failover.",
      secret?: false,
      required?: false,
      area: :tools_web,
      apps: [:lemon_core]
    },
    %{
      name: :lemon_web_search_max_results,
      env_var: "LEMON_WEB_SEARCH_MAX_RESULTS",
      aliases: [],
      type: :integer,
      default: 5,
      doc: "Maximum results returned per web search call.",
      secret?: false,
      required?: false,
      area: :tools_web,
      apps: [:lemon_core]
    },
    %{
      name: :lemon_web_search_provider,
      env_var: "LEMON_WEB_SEARCH_PROVIDER",
      aliases: [],
      type: :string,
      default: "brave",
      doc: "Web search provider id (e.g. brave, perplexity).",
      secret?: false,
      required?: false,
      area: :tools_web,
      apps: [:lemon_core]
    },
    %{
      name: :lemon_web_search_timeout,
      env_var: "LEMON_WEB_SEARCH_TIMEOUT",
      aliases: [],
      type: :integer,
      default: 30,
      doc: "Web search request timeout, in seconds.",
      secret?: false,
      required?: false,
      area: :tools_web,
      apps: [:lemon_core]
    },
    %{
      name: :lemon_tui_debug,
      env_var: "LEMON_TUI_DEBUG",
      aliases: [],
      type: :boolean,
      default: false,
      doc: "Whether the terminal UI runs in debug mode.",
      secret?: false,
      required?: false,
      area: :tui,
      apps: [:lemon_core, :lemon_cli]
    },
    %{
      name: :lemon_tui_theme,
      env_var: "LEMON_TUI_THEME",
      aliases: [],
      type: :string,
      default: "lemon",
      doc: "Terminal UI theme name.",
      secret?: false,
      required?: false,
      area: :tui,
      apps: [:lemon_core, :lemon_cli]
    },
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

  @doc """
  Returns every declared environment variable (name, env var, type,
  default, doc, secret?/required? flags, area, and owning apps).

  This is the source of truth behind `docs/config-registry.md` and is
  intended for tooling (e.g. a future `mix lemon.doctor` check) as well as
  interactive exploration.
  """
  @spec all_declared() :: [declaration()]
  def all_declared, do: @declarations

  @doc """
  Returns the declarations for a single `:area` (e.g. `:agent`, `:gateway`,
  `:arena`). See `all_declared/0` for the full list of areas in use.
  """
  @spec by_area(atom()) :: [declaration()]
  def by_area(area), do: Enum.filter(@declarations, &(&1.area == area))

  @doc """
  Returns the declaration for `name`, or `nil` if nothing is declared under
  that name.
  """
  @spec describe(atom()) :: declaration() | nil
  def describe(name), do: Enum.find(@declarations, &(&1.name == name))

  @doc """
  Resolves a declared environment variable by its registry name.

  Resolution order: `env_var` -> each of `aliases` (in declared order) ->
  `opts[:default]` -> the declaration's own `:default`. The resolved value
  is cast according to the declaration's `:type`.

  ## Options

    * `:default` - override the declaration's default for this call
    * `:required` - if true (or if the declaration has `required?: true`),
      raises `ArgumentError` when the value resolves to `nil`/`""`/`[]`

  ## Examples

      iex> LemonCore.Env.get(:lemon_web_port)
      4080

      iex> System.put_env("LEMON_ARENA_POKER_MODELS", "anthropic:claude-sonnet-4-20250514")
      iex> LemonCore.Env.get(:lemon_arena_poker_models)
      ["anthropic:claude-sonnet-4-20250514"]
  """
  @spec get(atom(), keyword()) :: term()
  def get(name, opts \\ []) do
    decl = declaration!(name)
    default = Keyword.get(opts, :default, decl.default)

    value =
      case find_set_env_var(decl) do
        nil -> default
        env_var -> cast(decl.type, env_var, default)
      end

    required? = Keyword.get(opts, :required, decl.required?)

    if required? and blank?(value) do
      raise ArgumentError,
            "Missing required environment variable: #{decl.env_var}#{alias_hint(decl)} " <>
              "(declared as #{inspect(decl.name)})"
    end

    value
  end

  @doc """
  Returns a redaction-safe snapshot of every declared variable's *current*
  resolved value, tagged with its resolution `:source` (`:env`, `:alias`,
  or `:default`). Secret-flagged values are redacted whenever the snapshot
  is inspected/logged (see `LemonCore.Env.Resolved`).
  """
  @spec snapshot() :: [LemonCore.Env.Resolved.t()]
  def snapshot do
    Enum.map(@declarations, fn decl ->
      {value, source} = resolve_with_source(decl)

      %LemonCore.Env.Resolved{
        name: decl.name,
        env_var: decl.env_var,
        value: value,
        source: source,
        secret?: decl.secret?
      }
    end)
  end

  @doc """
  Gets an optional raw (undeclared) string environment variable.
  """
  @spec string(String.t(), String.t() | nil) :: String.t() | nil
  def string(env_var, default \\ nil), do: Helpers.get_env(env_var, default)

  @doc """
  Gets a raw (undeclared) integer environment variable.
  """
  @spec int(String.t(), integer()) :: integer()
  def int(env_var, default \\ 0), do: Helpers.get_env_int(env_var, default)

  @doc """
  Gets a raw (undeclared) boolean environment variable.
  """
  @spec bool(String.t(), boolean()) :: boolean()
  def bool(env_var, default \\ false), do: Helpers.get_env_bool(env_var, default)

  @doc """
  Gets a raw (undeclared) list environment variable, split on `delimiter`.
  """
  @spec list(String.t(), String.t()) :: [String.t()]
  def list(env_var, delimiter \\ ","), do: Helpers.get_env_list(env_var, delimiter)

  # -- Internal ---------------------------------------------------------------

  defp declaration!(name) do
    case describe(name) do
      nil ->
        raise ArgumentError,
              "LemonCore.Env: no variable declared as #{inspect(name)}. " <>
                "Declare it in LemonCore.Env's @declarations, or use the raw " <>
                "string/2, int/2, bool/2, list/2 helpers for one-off variables."

      decl ->
        decl
    end
  end

  defp find_set_env_var(decl) do
    Enum.find([decl.env_var | decl.aliases], fn candidate -> Helpers.get_env(candidate) != nil end)
  end

  defp resolve_with_source(decl) do
    case find_set_env_var(decl) do
      nil -> {decl.default, :default}
      env_var when env_var == decl.env_var -> {cast(decl.type, env_var, decl.default), :env}
      env_var -> {cast(decl.type, env_var, decl.default), :alias}
    end
  end

  defp cast(:string, env_var, default), do: Helpers.get_env(env_var, default)
  defp cast(:integer, env_var, default), do: Helpers.get_env_int(env_var, default)
  defp cast(:float, env_var, default), do: Helpers.get_env_float(env_var, default)
  defp cast(:boolean, env_var, default), do: Helpers.get_env_bool(env_var, default)
  defp cast(:list, env_var, _default), do: Helpers.get_env_list(env_var)
  defp cast(:bytes, env_var, default), do: Helpers.get_env_bytes(env_var, default)

  defp alias_hint(%{aliases: []}), do: ""

  defp alias_hint(%{aliases: aliases}),
    do: " (also checked: #{Enum.join(aliases, ", ")})"

  defp blank?(nil), do: true
  defp blank?(""), do: true
  defp blank?([]), do: true
  defp blank?(_), do: false
end
