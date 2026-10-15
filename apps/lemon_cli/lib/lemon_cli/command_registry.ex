defmodule LemonCli.CommandRegistry.Metadata do
  @moduledoc false

  defmacro option(syntax, flags, summary) do
    quote do
      %{syntax: unquote(syntax), flags: unquote(flags), summary: unquote(summary)}
    end
  end

  defmacro subcommands(names) do
    quote do
      Enum.map(unquote(names), fn name ->
        %{name: name, summary: name |> String.replace("-", " ") |> String.capitalize()}
      end)
    end
  end

  defmacro lifecycle(name, usage, summary, launchers, details \\ []) do
    quote do
      %{
        name: unquote(name),
        summary: unquote(summary),
        usage: unquote(usage),
        options: [],
        subcommands: [],
        details: unquote(details),
        launchers: unquote(launchers)
      }
    end
  end

  defmacro runtime(name, handler, summary, usage, options, commands \\ []) do
    quote do
      %{
        name: unquote(name),
        summary: unquote(summary),
        usage: unquote(usage),
        options: unquote(options),
        subcommands: unquote(commands),
        handler: unquote(handler)
      }
    end
  end
end

defmodule LemonCli.CommandRegistry do
  @moduledoc """
  The single command registry shared by the source (`./bin/lemon`) and
  packaged (`lemon`) launchers.

  Two kinds of command live here:

    * CLI families (`commands/0`) are dispatched by `LemonCli.CLI` through
      Mix-free runtime modules in both launchers.
    * Lifecycle commands (`lifecycle_commands/1`) are handled by the launcher
      shell itself because they locate, start, stop, or attach to the runtime.

  Dispatch, top-level help, command help, and shell completion all consume
  this registry, filtered by `launcher/0`, so neither launcher ever advertises
  a command it cannot run.
  """

  import LemonCli.CommandRegistry.Metadata

  @commands [
    %{
      name: "acp",
      summary: "Serve ACP over stdio using the local runtime",
      usage: "lemon acp",
      subcommands: [],
      options: []
    },
    %{
      name: "tern",
      summary: "Install Lemon's Tern palette plugin and ACP agent",
      usage: "lemon tern install [--config-dir PATH]",
      subcommands: [
        %{name: "install", summary: "Install the palette plugin and register `tern acp lemon`"}
      ],
      options: [
        option(
          "--config-dir PATH",
          ["--config-dir"],
          "Tern configuration directory (not a config file)"
        )
      ]
    },
    %{
      name: "run",
      summary: "Run a prompt non-interactively (-p, --print)",
      usage: "lemon run [PROMPT] [--output text|json|stream-json] [options]",
      subcommands: [],
      options: [
        option("--output FORMAT", ["--output"], "text, json, or stream-json"),
        option("--model MODEL", ["--model"], "Provider:model override"),
        option("--cwd PATH", ["--cwd"], "Working directory"),
        option("--session KEY", ["--session"], "Resume a session"),
        option("--continue", ["--continue"], "Continue the latest CLI session"),
        option(
          "--approval-policy deny|allow",
          ["--approval-policy"],
          "Deny or allow approval requests"
        ),
        option("--allowed-tools LIST", ["--allowed-tools"], "Comma-separated tool allowlist"),
        option("--denied-tools LIST", ["--denied-tools"], "Comma-separated tool denylist")
      ]
    },
    %{
      name: "setup",
      summary: "Run first-time setup and configuration",
      usage: "lemon setup [provider|runtime|gateway|doctor] [options]",
      subcommands: [
        %{name: "provider", summary: "Configure an AI provider"},
        %{name: "runtime", summary: "Configure runtime profile and port bindings"},
        %{name: "gateway", summary: "Configure gateway adapters"},
        %{name: "doctor", summary: "Run diagnostics or write a support bundle (alias for doctor)"}
      ],
      options: [
        option("--non-interactive, -n", ["--non-interactive", "-n"], "Skip prompts"),
        option("--config-path PATH", ["--config-path"], "Config file to read or write"),
        option("--skip-verify", ["--skip-verify"], "Defer live provider verification"),
        option("--daily-brief HH:MM", ["--daily-brief"], "Daily brief time (non-interactive)"),
        option("--set-default", ["--set-default"], "Set the provider and model as defaults"),
        option(
          "--provider NAME",
          ["--provider"],
          "Provider to sign in to (openai-codex for ChatGPT)"
        ),
        option("--token TOKEN", ["--token"], "Credential for non-interactive provider setup"),
        option(
          "--auth oauth|device|api_key|codex-cli",
          ["--auth"],
          "Authentication mode (import is opt-in)"
        ),
        option(
          "--codex-auth-path PATH",
          ["--codex-auth-path"],
          "Auth file for --auth codex-cli only"
        ),
        option("--model MODEL", ["--model"], "Model to make the default after onboarding"),
        option(
          "--if-required",
          ["--if-required"],
          "Exit immediately unless setup is still required"
        )
      ]
    },
    %{
      name: "model",
      summary: "Configure an AI provider",
      usage: "lemon model [provider] [options]",
      subcommands: [],
      options: [
        option("--provider NAME", ["--provider"], "Provider id"),
        option("--token TOKEN", ["--token"], "Provider credential"),
        option(
          "--auth oauth|device|api_key|codex-cli",
          ["--auth"],
          "Authentication mode (import is opt-in)"
        ),
        option(
          "--codex-auth-path PATH",
          ["--codex-auth-path"],
          "Auth file for --auth codex-cli only"
        ),
        option(
          "--non-interactive",
          ["--non-interactive"],
          "Require --token, --auth device or --auth codex-cli"
        ),
        option("--secret-name NAME", ["--secret-name"], "Secret to store, inspect, or log out"),
        option("--model MODEL", ["--model"], "Default model with --set-default"),
        option("--set-default", ["--set-default"], "Set the provider and model as defaults"),
        option("--config-path PATH", ["--config-path"], "Config file to update"),
        option("--status", ["--status"], "Show the provider's sign-in and credential status"),
        option("--logout", ["--logout"], "Delete the stored OAuth login and its config")
      ],
      details: [
        "Without a provider, Lemon displays an interactive picker. Credentials are stored in the encrypted secrets store and referenced from config.toml.",
        "`lemon model anthropic` signs in with a Claude Pro/Max subscription in the browser; `--status` and `--logout` need a provider.",
        "`lemon model openai-codex --auth device` signs in to ChatGPT with a device code (no local callback); `openrouter`, `xai`, `kimi_coding` and `zai` also offer subscription sign-in."
      ]
    },
    %{
      name: "gateway",
      summary: "Configure a gateway adapter",
      usage: "lemon gateway setup [--transport NAME] [options]",
      subcommands: [%{name: "setup", summary: "Configure Telegram or Discord"}],
      options: [
        option("--transport NAME, -t NAME", ["--transport", "-t"], "Gateway adapter"),
        option("--non-interactive, -n", ["--non-interactive", "-n"], "Skip prompts"),
        option("--token TOKEN", ["--token"], "Bot token to store in encrypted secrets"),
        option("--chat-id ID", ["--chat-id"], "Telegram chat to allow (repeatable)"),
        option("--pair-timeout SECONDS", ["--pair-timeout"], "Telegram /start pairing wait")
      ],
      details: [
        "Telegram setup pairs the bot with your chat: send /start to the bot when prompted, or pass --chat-id. An unpaired bot ignores every chat."
      ]
    },
    %{
      name: "doctor",
      summary: "Run diagnostics or write a support bundle",
      usage: "lemon doctor [options]",
      subcommands: [],
      options: [
        option("--verbose, -v", ["--verbose", "-v"], "Show passing and skipped checks"),
        option("--json", ["--json"], "Output one JSON document"),
        option("--project-dir PATH", ["--project-dir"], "Use a specific project directory"),
        option("--bundle [PATH]", ["--bundle"], "Write a redacted support bundle"),
        option("--bundle-path PATH", ["--bundle-path"], "Set the support bundle path")
      ]
    },
    %{
      name: "config",
      summary: "Validate, show or migrate configuration",
      usage: "lemon config [validate|show|migrate] [options]",
      subcommands: [
        %{name: "validate", summary: "Validate the resolved configuration"},
        %{name: "show", summary: "Show the resolved configuration summary"},
        %{
          name: "migrate",
          summary: "Rewrite deprecated sections in global and project config (keeps a backup)"
        }
      ],
      options: [
        option("--verbose, -v", ["--verbose", "-v"], "Verbose output"),
        option(
          "--project-dir, -p PATH",
          ["--project-dir", "-p"],
          "Project directory for project config"
        )
      ]
    },
    %{
      name: "mcp",
      summary: "Manage and test named MCP servers",
      usage:
        "lemon mcp add NAME (--stdio COMMAND [-- ARG...] | --http URL) [options]\n       lemon mcp list [--all]|remove NAME|test NAME|enable NAME|disable NAME [options]",
      subcommands: subcommands(~w(add list remove test enable disable)),
      options: [
        option(
          "--global",
          ["--global"],
          "Use the global agent MCP file instead of project config"
        ),
        option("--cwd PATH", ["--cwd"], "Project root (default: current directory)"),
        option(
          "--all",
          ["--all"],
          "list: effective servers incl. other tools' configs, with source and state"
        ),
        option("--stdio COMMAND", ["--stdio"], "Executable; pass its arguments after --"),
        option("--http URL", ["--http"], "Streamable HTTP MCP endpoint"),
        option("--env KEY=VALUE", ["--env"], "Stdio environment entry (repeatable)"),
        option("--header KEY=VALUE", ["--header"], "HTTP header (repeatable)"),
        option(
          "--approval always|never",
          ["--approval"],
          "Server approval default (add: always)"
        ),
        option(
          "--tool-approval TOOL=always|never",
          ["--tool-approval"],
          "Exact remote tool override (repeatable)"
        ),
        option(
          "--replace",
          ["--replace"],
          "Replace a unique existing name, preserving extensions"
        ),
        option("--json", ["--json"], "Emit redacted JSON")
      ]
    },
    %{
      name: "secrets",
      summary: "Manage encrypted secrets",
      usage: "lemon secrets <command> [args]",
      subcommands: [
        %{name: "status", summary: "Show safe secrets-store status"},
        %{name: "init", summary: "Initialize the master key"},
        %{name: "set", summary: "Store one secret"},
        %{name: "list", summary: "List metadata without values"},
        %{name: "delete", summary: "Delete one secret"},
        %{name: "check", summary: "Check configured credential sources"},
        %{name: "import-env", summary: "Import selected environment credentials"},
        %{name: "rotate-key", summary: "Preview or apply a master-key rotation"},
        %{name: "sources", summary: "Inspect or test external secret sources"}
      ],
      options: [
        option("--target file|keychain", ["--target"], "Master-key target for init"),
        option("--provider NAME", ["--provider"], "Metadata provider for set"),
        option("--expires-at N", ["--expires-at"], "Expiry timestamp for set"),
        option("--dry-run", ["--dry-run"], "Preview environment imports"),
        option("--force", ["--force"], "Confirm the selected replacement operation"),
        option("--confirm TOKEN", ["--confirm"], "Exact rotate-key preview token"),
        option("--project-dir PATH", ["--project-dir"], "Project directory for source config"),
        option("--source-id ID", ["--source-id"], "Test one external source"),
        option("--json", ["--json"], "Emit redacted source readiness JSON")
      ],
      details: [
        "rotate-key previews by default and changes nothing. Applying requires the exact preview token, refuses while a Lemon runtime is running, and re-encrypts every stored secret under a new master key written to the Keychain entry or key file that supplied the current one."
      ]
    },
    %{
      name: "channels",
      summary: "Inspect channel configuration",
      usage: "lemon channels [options]",
      subcommands: [],
      options: [
        option("--project-dir PATH", ["--project-dir"], "Project root to read config from"),
        option("--json", ["--json"], "Emit redacted channel diagnostics JSON")
      ]
    },
    %{
      name: "providers",
      summary: "Inspect provider readiness and manage routing",
      usage: "lemon providers [status|fallback|pool] [options]",
      subcommands: subcommands(~w(status fallback pool)),
      options: [
        option("--provider NAME, -p NAME", ["--provider", "-p"], "Filter or add a provider"),
        option("--include-catalog", ["--include-catalog"], "Include every known provider"),
        option("--project-dir PATH", ["--project-dir"], "Resolve project configuration"),
        option("--scope global|project", ["--scope"], "Configuration target"),
        option("--config-path PATH", ["--config-path"], "Explicit configuration path"),
        option("--dry-run", ["--dry-run"], "Preview without writing"),
        option("--confirm VALUE", ["--confirm"], "Exact destructive-change confirmation"),
        option("--strategy priority|round_robin", ["--strategy"], "Credential-pool strategy"),
        option("--activate", ["--activate"], "Make the selected pool the default"),
        option("--json", ["--json"], "Emit one redacted JSON document")
      ],
      details: [
        "Fallback commands: list, add PROVIDER, remove PROVIDER, clear.",
        "Pool commands: list, set POOL, delete POOL, and credential add/remove/clear. Credential references remain in the existing encrypted store or environment; values are never copied into TOML or status output.",
        "Mutations preserve comments, preview safely, and require the exact confirmation value when removing configured routing state."
      ]
    },
    %{
      name: "blueprints",
      summary: "Review and activate cataloged skill automation blueprints",
      usage: "lemon blueprints [list|inspect|validate|preview|activate] [options]",
      subcommands: subcommands(~w(list inspect validate preview activate)),
      options: [
        option("--profile ID", ["--profile"], "Target profile for preview or activation"),
        option("--confirm DIGEST", ["--confirm"], "Exact digest from a fresh preview"),
        option("--json", ["--json"], "Emit one sanitized JSON document")
      ],
      details: [
        "With no arguments, the command lists the local catalog. A bundle ID plus --profile is shorthand for preview and never mutates state.",
        "Activation accepts catalog IDs only and requires the exact confirmation digest from a fresh plan. Bundle paths, archives, commands, environment overrides, and secret values are not CLI inputs."
      ]
    },
    %{
      name: "profile",
      summary: "Manage isolated agent profiles",
      usage: "lemon profile <command> [options]",
      subcommands: subcommands(~w(list show create clone rename export delete roster chat)),
      options: [
        option("--json", ["--json"], "Emit JSON"),
        option("--name NAME", ["--name"], "Profile display name"),
        option("--model MODEL", ["--model"], "Profile or chat model"),
        option("--node NODE", ["--node"], "Named execution node"),
        option("--queue-mode MODE", ["--queue-mode"], "Chat queue mode"),
        option("--confirm ID", ["--confirm"], "Exact profile deletion confirmation"),
        option("--force", ["--force"], "Replace an existing export file")
      ],
      details: [
        "Lifecycle commands keep profiles under the canonical Lemon home. Exports are credential-safe selected-file snapshots and never include sessions or memory."
      ]
    },
    %{
      name: "backup",
      summary: "Back up or restore durable user state",
      usage: "lemon backup <contract|create|list|verify|restore> [options]",
      subcommands: subcommands(~w(contract create list verify restore)),
      options: [
        option("--output PATH", ["--output"], "Output bundle path"),
        option("--root PATH", ["--root"], "Backup root to list"),
        option("--target PATH", ["--target"], "Restore target"),
        option("--include-credentials", ["--include-credentials"], "Include local credentials"),
        option("--overwrite", ["--overwrite"], "Allow verified differing files"),
        option("--confirm TOKEN", ["--confirm"], "Exact verify token"),
        option("--json", ["--json"], "Emit one JSON document")
      ],
      details: [
        "Restore verifies before mutation. Credential material is excluded unless --include-credentials is explicit. Secret values and backed-up file contents are never printed.",
        "Exit codes: 0 success; 1 verification or operational failure; 2 invalid command or options."
      ]
    },
    %{
      name: "context",
      summary: "Preview or resolve bounded context references",
      usage: "lemon context <preview|resolve> <reference>... [options]",
      subcommands: subcommands(~w(preview resolve)),
      options: [
        option("--root PATH", ["--root"], "Root for confined file references"),
        option("--json", ["--json"], "Emit JSON"),
        option("--max-bytes N", ["--max-bytes"], "Bound selected bytes"),
        option("--max-items N", ["--max-items"], "Bound selected items"),
        option("--max-depth N", ["--max-depth"], "Bound folder traversal depth"),
        option("--max-pages N", ["--max-pages"], "Bound document pages"),
        option("--timeout-ms N", ["--timeout-ms"], "Bound external resolution time")
      ]
    },
    %{
      name: "sessions",
      summary: "Inspect and manage durable sessions",
      usage: "lemon sessions <command> [options]",
      subcommands:
        subcommands(
          ~w(list search stats show history context title pin unpin archive restore export prune delete)
        ),
      options: [
        option("--json", ["--json"], "Emit one redacted JSON document"),
        option("--limit N", ["--limit"], "Bound rows or history entries"),
        option("--offset N", ["--offset"], "Skip list/search rows"),
        option("--group-limit N", ["--group-limit"], "Bound stats dimension entries"),
        option("--agent-id ID", ["--agent-id"], "Filter by agent id"),
        option("--pinned | --unpinned", ["--pinned", "--unpinned"], "Filter pin state"),
        option("--archived | --active", ["--archived", "--active"], "Filter archive state"),
        option("--format json|jsonl|markdown|html", ["--format"], "Redacted export format"),
        option("--cwd PATH", ["--cwd"], "Project directory for context (default: current)"),
        option("--clear", ["--clear"], "Clear a session title"),
        option("--output PATH", ["--output"], "Write export content to a private file"),
        option("--force", ["--force"], "Replace an existing regular export file"),
        option("--older-than AGE|DATE", ["--older-than"], "Prune cutoff, for example 30d"),
        option("--all", ["--all"], "Allow non-archived prune candidates"),
        option("--include-pinned", ["--include-pinned"], "Allow pinned prune candidates"),
        option("--confirm TOKEN", ["--confirm"], "Exact preview or delete confirmation")
      ],
      details: [
        "Stats returns exact aggregate counts with bounded, redacted agent and origin dimensions. History and exports are always redacted. Prune previews by default and executes only with the exact token from an unchanged candidate set. Delete requires the exact session key.",
        "Context shows a native session's context-window usage by category (system prompt, tools, skills, context files, memory, messages, free space); splits are estimates scaled to the provider-reported total."
      ]
    },
    %{
      name: "omp",
      summary: "Start, watch, and steer omp coding-agent sessions",
      usage: "lemon omp <command> [args] [options]",
      subcommands: [
        %{name: "status", summary: "Show whether omp is installed and live-session counts"},
        %{name: "list", summary: "List live omp sessions (--all includes ended ones)"},
        %{name: "show", summary: "Summarize one session: show ID"},
        %{name: "discover", summary: "List omp's stored sessions for a workspace"},
        %{name: "start", summary: "Start omp on a prompt: start [options] PROMPT..."},
        %{name: "start-many", summary: "Start parallel workers with repeated --task PROMPT"},
        %{name: "models", summary: "List omp models: models [QUERY] [--free] [--provider P]"},
        %{name: "subagent", summary: "Read a transcript tail: subagent ID SUBAGENT-ID"},
        %{name: "configure", summary: "Change a worker: configure ID [--model M] [--thinking L]"},
        %{
          name: "send",
          summary: "Steer, follow up or redirect: send ID [--follow-up|--redirect] MESSAGE..."
        },
        %{name: "cancel", summary: "Abort the running turn; the session stays open"},
        %{name: "close", summary: "End the omp process; it stays resumable"},
        %{name: "resume", summary: "Reopen a stored session: resume OMP-ID [PROMPT...]"},
        %{name: "watch", summary: "Follow a session until its turn settles"}
      ],
      options: [
        option("--cwd PATH", ["--cwd"], "Workspace for start, resume, discover (default: .)"),
        option(
          "--model MODEL",
          ["--model"],
          "omp model for start, start-many, resume or configure"
        ),
        option(
          "--thinking LEVEL",
          ["--thinking"],
          "Thinking level for start, start-many, resume or configure"
        ),
        option(
          "--approval-mode MODE",
          ["--approval-mode"],
          "always-ask, write or yolo (start/start-many/resume)"
        ),
        option("--isolate", ["--isolate"], "Create managed Git worktrees (start/start-many)"),
        option("--continue", ["--continue"], "Continue interrupted history on resume; no prompt"),
        option("--task PROMPT", ["--task"], "Repeat 1–8 times for start-many"),
        option("--free", ["--free"], "Only free omp models"),
        option("--provider PROVIDER", ["--provider"], "Filter omp model provider"),
        option("--redirect", ["--redirect"], "Stop the current turn and replace its prompt"),
        option("--follow-up", ["--follow-up"], "Queue a send after the running turn"),
        option("--all", ["--all"], "Include ended sessions in list"),
        option(
          "--limit N",
          ["--limit"],
          "Bound rows: list/discover max 100, models 200, subagent 50"
        ),
        option("--json", ["--json"], "Emit JSON")
      ],
      details: [
        "omp runs inside the Lemon runtime, which starts first when needed. Without a subcommand, lemon omp lists live sessions. Text from omp is untrusted and printed with control characters removed.",
        "Leaving watch (including Ctrl-C) never cancels the omp turn. A send or cancel reported as not retry-safe may already have taken effect; check `lemon omp show ID` before retrying."
      ]
    },
    %{
      name: "learning",
      summary: "Browse the current profile's learning timeline",
      usage:
        "lemon learning [--profile ID] [--kind memory|user|project|skill] [--limit N] [--json]",
      subcommands: [],
      options: [
        option("--profile ID", ["--profile"], "Local profile (default: default assistant)"),
        option("--kind KIND", ["--kind"], "Filter memory, user, project, or skill events"),
        option("--limit N", ["--limit"], "Maximum events, 1–100 (default 50)"),
        option("--json", ["--json"], "Emit one redacted JSON document")
      ],
      details: [
        "Newest first. Existing creation/latest-update timestamps only, not a complete historical log. Previews show current redacted content.",
        "Use the existing memory management and skill commands to edit/delete; this command never mutates state."
      ]
    },
    %{
      name: "learn",
      summary: "Review and confirm bounded learning from sources",
      usage: "lemon learn [review|confirm] <reference>... [options]",
      subcommands: subcommands(~w(review confirm)),
      options: [
        option("--root PATH", ["--root"], "Root for confined local sources"),
        option("--agent-id ID", ["--agent-id"], "Durable memory owner"),
        option("--session-key KEY", ["--session-key"], "Explicit learning session"),
        option("--project", ["--project"], "Use the project draft scope"),
        option("--confirm DIGEST", ["--confirm"], "Exact digest from a fresh review"),
        option("--json", ["--json"], "Emit one sanitized JSON document")
      ],
      details: [
        "Review is the default and never writes state. Confirm re-resolves every source and fails closed when source content, audit state, or destination conflicts changed.",
        "Output contains hashes, counts, audit codes, and conflict state only; source text, prompts, paths, URLs, secret names, and secret values are omitted."
      ]
    },
    %{
      name: "update",
      summary: "Safely plan, apply, inspect, or roll back Lemon releases",
      usage: "lemon update <check|plan|apply|history|rollback> [options]",
      subcommands: subcommands(~w(check plan apply history rollback)),
      options: [
        option("--channel CHANNEL", ["--channel"], "Override the release channel"),
        option("--version VERSION", ["--version"], "Use an exact published version"),
        option("--confirm DIGEST", ["--confirm"], "Exact fresh plan or rollback digest"),
        option("--receipt ID", ["--receipt"], "Exact update receipt for rollback"),
        option("--limit N", ["--limit"], "Bound history receipts"),
        option("--json", ["--json"], "Emit one redacted JSON document")
      ],
      details: [
        "Planning is non-mutating. Managed-release apply requires the exact digest from a fresh plan; rollback requires both the exact apply receipt and its rollback digest.",
        "Source checkouts support read-only check/history. Plan, apply, and rollback fail closed because source updates belong to the operator's reviewed git workflow."
      ]
    },
    %{
      name: "completion",
      summary: "Generate shell completion scripts",
      usage: "lemon completion <bash|zsh|fish>",
      subcommands: subcommands(~w(bash zsh fish)),
      options: [],
      details: [
        "The generated script matches the invoking launcher. Release VM tools (remote, eval, rpc) are only advertised by packaged installs."
      ]
    },
    %{
      name: "migrate",
      summary: "Import user data from a Hermes home",
      usage: "lemon migrate hermes [audit] [options]",
      subcommands: [
        %{name: "hermes", summary: "Preview, then import a Hermes home into Lemon"},
        %{name: "audit", summary: "Read-only compatibility audit (`migrate hermes audit`)"}
      ],
      options: [
        option("--source PATH", ["--source"], "Hermes home (default: ~/.hermes)"),
        option("--target PATH", ["--target"], "Lemon home (default: ~/.lemon)"),
        option("--workspace-dir PATH", ["--workspace-dir"], "Assistant workspace override"),
        option("--preset user-data|full", ["--preset"], "Import scope (default: user-data)"),
        option("--migrate-secrets", ["--migrate-secrets"], "Import allowlisted secrets"),
        option("--skill-conflict skip|rename", ["--skill-conflict"], "Existing skill policy"),
        option("--dry-run", ["--dry-run"], "Preview without writing"),
        option("--yes", ["--yes"], "Apply without prompting"),
        option("--overwrite", ["--overwrite"], "Replace conflicting target files"),
        option("--no-backup", ["--no-backup"], "Skip the pre-migration zip backup"),
        option("--json", ["--json"], "Emit the audit as JSON")
      ],
      details: [
        "Migration always previews first and refuses conflicts unless --overwrite is set. Without --yes it asks before writing. Secret values are never printed or written to reports."
      ]
    },
    %{
      name: "node",
      summary: "Inspect worker compatibility or join a named execution node",
      usage:
        "lemon node join --name NAME --controller wss://HOST/ws [options]\nlemon node capabilities [--json] [--require-bot] [--expected-version VERSION]",
      subcommands: [
        %{name: "join", summary: "Pair with or reconnect to a controller"},
        %{
          name: "capabilities",
          summary: "Inspect installed worker API compatibility without starting a runtime"
        }
      ],
      options: [
        option("--json", ["--json"], "Print worker compatibility JSON (capabilities)"),
        option(
          "--require-bot",
          ["--require-bot"],
          "Fail if required bot worker APIs are absent (capabilities)"
        ),
        option(
          "--expected-version VERSION",
          ["--expected-version"],
          "Require the exact installed worker CalVer (capabilities)"
        ),
        option("--name NAME", ["--name"], "Unique execution node name"),
        option("--controller URL", ["--controller"], "Controller control-plane WebSocket"),
        option("--pair", ["--pair"], "Pair and store a controller-issued node token"),
        option(
          "--invite-code-stdin",
          ["--invite-code-stdin"],
          "Read one bounded enrollment or repair code from stdin (implies --pair)"
        ),
        option("--node-id ID", ["--node-id"], "Durable controller node ID"),
        option("--repair", ["--repair"], "Operator-authorized legacy credential repair"),
        option(
          "--allow-insecure-controller",
          ["--allow-insecure-controller"],
          "Allow non-loopback ws://"
        ),
        option("--cwd PATH", ["--cwd"], "Default local working directory"),
        option(
          "--allowed-root PATH",
          ["--allowed-root"],
          "Allowed host file/shell root (repeatable)"
        )
      ]
    },
    %{
      name: "version",
      summary: "Print the Lemon version (--version includes build identity)",
      usage: "lemon version [--verbose]",
      subcommands: [],
      options: [option("--verbose", ["--verbose"], "Show source/release, commit, and channel")]
    },
    runtime(
      "send",
      LemonChannels.ScriptSend.CLI,
      "Send a Telegram or Discord notification",
      "lemon send --to TARGET [options] [message]",
      [
        option("--to TARGET", ["--to"], "Telegram or Discord target"),
        option("--account NAME", ["--account"], "Channel account"),
        option("--subject TEXT", ["--subject"], "Message subject"),
        option("--file PATH", ["--file"], "Read body from a file, or - for stdin"),
        option("--attach PATH", ["--attach"], "Attach a local file (repeatable)"),
        option("--thread ID, --topic ID", ["--thread", "--topic"], "Thread or topic"),
        option("--reply-to ID", ["--reply-to"], "Reply to a platform message"),
        option("--list [PLATFORM]", ["--list"], "List known targets"),
        option("--dry-run", ["--dry-run"], "Validate without sending"),
        option("--quiet", ["--quiet"], "Suppress normal output"),
        option("--json", ["--json"], "Emit JSON")
      ]
    ),
    runtime(
      "media",
      LemonMedia.CLI,
      "Inspect media generation diagnostics",
      "lemon media [options]",
      [
        option("--project-dir PATH", ["--project-dir"], "Project root"),
        option("--limit N", ["--limit"], "Recent jobs to show"),
        option("--json", ["--json"], "Emit redacted JSON")
      ]
    ),
    runtime(
      "models",
      LemonAi.Models.CLI,
      "List the model catalog",
      "lemon models [options]",
      [
        option("--provider NAME", ["--provider", "-p"], "Filter by provider"),
        option("--vision", ["--vision"], "Only image-capable models"),
        option("--thinking", ["--thinking"], "Only reasoning-capable models"),
        option("--limit N", ["--limit", "-l"], "Maximum rows"),
        option("--json", ["--json"], "Emit catalog and summary JSON"),
        option("--discover", ["--discover"], "Query a preset provider endpoint for its models"),
        option("--base-url URL", ["--base-url"], "Endpoint for --discover")
      ]
    ),
    runtime(
      "policy",
      LemonChannels.ModelPolicy.CLI,
      "Manage model policies",
      "lemon policy <list|set|get|clear> [channel] [options]",
      [
        option("--account ID", ["--account", "-a"], "Channel account"),
        option("--peer ID", ["--peer", "-p"], "Peer or chat"),
        option("--thread ID", ["--thread", "-t"], "Thread or topic"),
        option("--model MODEL", ["--model", "-m"], "Model override"),
        option("--thinking LEVEL", ["--thinking"], "Thinking override"),
        option("--reason TEXT", ["--reason", "-r"], "Policy metadata reason"),
        option("--all", ["--all"], "Clear all policies for the channel")
      ],
      subcommands(~w(list set get clear))
    ),
    runtime(
      "skill",
      LemonSkills.CLI,
      "Manage installed skills",
      "lemon skill <command> [args]",
      [
        option("--cwd PATH", ["--cwd"], "Project workspace"),
        option("--local", ["--local"], "Install only in the project"),
        option("--global", ["--global"], "Use global skills"),
        option("--force", ["--force"], "Confirm overwrite or removal"),
        option("--no-online", ["--no-online"], "Search only installed skills"),
        option("--active", ["--active"], "Browse only active skills"),
        option("--not-ready", ["--not-ready"], "Browse skills missing dependencies"),
        option("--all", ["--all"], "Include hidden skills when browsing")
      ],
      subcommands(
        ~w(list browse search discover hermes install update remove inspect check info draft curator)
      )
    ),
    runtime(
      "usage",
      LemonCore.Usage.CLI,
      "Inspect usage diagnostics",
      "lemon usage [--json]",
      [option("--json", ["--json"], "Emit redacted usage JSON")]
    )
  ]

  @both_launchers [:source, :release]

  @runtime_options_detail "Source checkouts accept --debug, --port N, --web-port N, --sim-port N, --name NAME@HOST or --sname NAME, --cookie COOKIE, and --no-distribution. Packaged installs read LEMON_CONTROL_PLANE_PORT, LEMON_WEB_PORT, and LEMON_SIM_UI_PORT. A healthy runtime already answering on the control-plane port is reused instead of starting a second node."

  @lifecycle_commands [
    lifecycle(
      "tui",
      "lemon tui [tui args]",
      "Open the terminal UI, starting the runtime if needed",
      @both_launchers,
      [
        "`lemon` with no command in an interactive terminal does the same. Before starting a runtime for the first time, unfinished setup runs interactively (`lemon setup --if-required`).",
        "`lemon -c` / `lemon --continue` reopens the most recently updated TUI session started from this directory; `lemon -r [KEY]` / `--resume [KEY]` attaches to KEY or, without one, opens the session switcher. `--session KEY` attaches to an exact session; the three are mutually exclusive."
      ]
    ),
    lifecycle(
      "web",
      "lemon web [--no-open]",
      "Open the local Web UI, starting the runtime if needed",
      @both_launchers,
      [
        "Set LEMON_WEB_PORT to use a port other than 4080; --no-open only prints the URL. Packaged installs need the lemon_runtime_full profile."
      ]
    ),
    lifecycle(
      "start",
      "lemon start [runtime options]",
      "Run the runtime in the foreground",
      @both_launchers,
      [@runtime_options_detail]
    ),
    lifecycle(
      "daemon",
      "lemon daemon [runtime options]",
      "Run the runtime in the background and wait until it is healthy",
      @both_launchers,
      [@runtime_options_detail]
    ),
    lifecycle("stop", "lemon stop", "Stop the background runtime", @both_launchers, [
      "Select the daemon with LEMON_CONTROL_PLANE_PORT; source checkouts also accept --port N and verify the recorded process start identity before signalling it."
    ]),
    lifecycle(
      "restart",
      "lemon restart [runtime options]",
      "Restart the background runtime",
      @both_launchers
    ),
    lifecycle("status", "lemon status", "Report runtime pid and health", @both_launchers, [
      "Select the daemon with LEMON_CONTROL_PLANE_PORT; source checkouts also accept --port N."
    ]),
    lifecycle("remote", "lemon remote", "Attach a remote IEx shell to the runtime", [:release]),
    lifecycle("eval", "lemon eval EXPR", "Evaluate EXPR in a fresh release VM", [:release]),
    lifecycle("rpc", "lemon rpc EXPR", "Evaluate EXPR on the running runtime", [:release])
  ]

  @spec commands() :: [map()]
  def commands, do: @commands

  @spec names() :: [String.t()]
  def names, do: Enum.map(@commands, & &1.name)

  @spec command?(String.t()) :: boolean()
  def command?(name) when is_binary(name), do: name in names()

  @doc "Whether `name` is a lifecycle command handled by the launcher shell."
  @spec lifecycle?(String.t()) :: boolean()
  def lifecycle?(name) when is_binary(name),
    do: Enum.any?(@lifecycle_commands, &(&1.name == name))

  @spec fetch(String.t()) :: {:ok, map()} | :error
  def fetch(name) when is_binary(name) do
    case Enum.find(@commands ++ @lifecycle_commands, &(&1.name == name)) do
      nil -> :error
      command -> {:ok, command}
    end
  end

  @doc "The launcher that invoked the CLI, as exported by `bin/lemon`."
  @spec launcher() :: :source | :release
  def launcher do
    case System.get_env("LEMON_CLI_LAUNCHER") do
      "source" -> :source
      _other -> :release
    end
  end

  @spec available?(map(), :source | :release) :: boolean()
  def available?(command, launcher),
    do: launcher in Map.get(command, :launchers, @both_launchers)

  @spec lifecycle_commands(:source | :release) :: [map()]
  def lifecycle_commands(launcher),
    do: Enum.filter(@lifecycle_commands, &available?(&1, launcher))

  @spec completion_commands(:source | :release) :: [map()]
  def completion_commands(launcher) do
    (@commands ++ @lifecycle_commands)
    |> Enum.filter(&available?(&1, launcher))
    |> Enum.sort_by(& &1.name)
  end

  @spec help() :: String.t()
  def help, do: overview(launcher())

  @spec overview(:source | :release) :: String.t()
  def overview(launcher) do
    """
    Usage: lemon <command> [options]

    With no command in an interactive terminal, lemon opens the TUI and starts
    the runtime first when needed.

    Runtime:
    #{summary_lines(lifecycle_commands(launcher))}

    Commands:
    #{summary_lines(Enum.filter(@commands, &available?(&1, launcher)))}

    Flags:
      --version    Print build identity (use alone; for options, use lemon version --verbose).

    Run `lemon <command> --help` for command options.
    """
  end

  @spec help(String.t()) :: String.t()
  def help(name) do
    case fetch(name) do
      {:ok, command} ->
        render_help(command)

      :error ->
        IO.puts(:stderr, "Unknown command: #{name}. Run `lemon --help` to list commands.")
        help()
    end
  end

  defp summary_lines(commands) do
    Enum.map_join(commands, "\n", fn command ->
      "  #{String.pad_trailing(command.name, 12)} #{command.summary}"
    end)
  end

  defp render_help(command) do
    sections = ["Usage: #{command.usage}", "", command.summary]

    sections =
      if command.subcommands == [] do
        sections
      else
        subcommands =
          Enum.map(command.subcommands, fn subcommand ->
            "  #{String.pad_trailing(subcommand.name, 14)} #{subcommand.summary}"
          end)

        sections ++ ["", "Commands:" | subcommands]
      end

    sections =
      if command.options == [] do
        sections
      else
        options =
          Enum.map(command.options, fn option ->
            "  #{String.pad_trailing(option.syntax, 29)} #{option.summary}"
          end)

        sections ++ ["", "Options:" | options]
      end

    sections =
      case Map.get(command, :details, []) do
        [] -> sections
        details -> sections ++ ["" | details]
      end

    Enum.join(sections, "\n") <> "\n"
  end
end
