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

  defmacro launcher(name, summary, subcommand_names \\ []) do
    quote do
      %{
        name: unquote(name),
        summary: unquote(summary),
        usage: nil,
        options: [],
        subcommands: subcommands(unquote(subcommand_names))
      }
    end
  end
end

defmodule LemonCli.CommandRegistry do
  @moduledoc """
  Canonical metadata for the Mix-free Lemon command families.

  Dispatch, top-level help, command help, and shell completion generation all
  consume this registry. Launcher-only commands are kept in separate source
  and release sets so completion never advertises a command unavailable in the
  launcher that generated it.
  """

  import LemonCli.CommandRegistry.Metadata

  @commands [
    %{
      name: "setup",
      summary: "Run first-time setup and configuration",
      usage: "lemon setup [provider|runtime|gateway|doctor] [options]",
      subcommands: [
        %{name: "provider", summary: "Configure an AI provider"},
        %{name: "runtime", summary: "Configure runtime profile and port bindings"},
        %{name: "gateway", summary: "Configure gateway adapters"},
        %{name: "doctor", summary: "Validate config and report health"}
      ],
      options: [
        option("--non-interactive, -n", ["--non-interactive", "-n"], "Skip prompts"),
        option("--config-path PATH", ["--config-path"], "Config file to read or write"),
        option("--skip-verify", ["--skip-verify"], "Defer live provider verification")
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
        option("--auth oauth|api_key", ["--auth"], "Authentication mode"),
        option("--secret-name NAME", ["--secret-name"], "Encrypted secret name"),
        option("--model MODEL", ["--model"], "Default model with --set-default"),
        option("--set-default", ["--set-default"], "Set the provider and model as defaults"),
        option("--config-path PATH", ["--config-path"], "Config file to update")
      ],
      details: [
        "Without a provider, Lemon displays an interactive picker. Credentials are stored in the encrypted secrets store and referenced from config.toml."
      ]
    },
    %{
      name: "gateway",
      summary: "Configure a gateway adapter",
      usage: "lemon gateway setup [transport] [options]",
      subcommands: [%{name: "setup", summary: "Configure Telegram or Discord"}],
      options: [
        option("--transport NAME, -t NAME", ["--transport", "-t"], "Gateway adapter"),
        option("--non-interactive, -n", ["--non-interactive", "-n"], "Skip prompts")
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
      summary: "Validate or show configuration",
      usage: "lemon config [validate|show] [options]",
      subcommands: [
        %{name: "validate", summary: "Validate the resolved configuration"},
        %{name: "show", summary: "Show the resolved configuration summary"}
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
        %{name: "sources", summary: "Inspect or test external secret sources"}
      ],
      options: [
        option("--target file|keychain", ["--target"], "Master-key target for init"),
        option("--provider NAME", ["--provider"], "Metadata provider for set"),
        option("--expires-at N", ["--expires-at"], "Expiry timestamp for set"),
        option("--dry-run", ["--dry-run"], "Preview environment imports"),
        option("--force", ["--force"], "Confirm the selected replacement operation"),
        option("--project-dir PATH", ["--project-dir"], "Project directory for source config"),
        option("--source-id ID", ["--source-id"], "Test one external source"),
        option("--json", ["--json"], "Emit redacted source readiness JSON")
      ]
    },
    %{
      name: "channels",
      summary: "Inspect channel launch readiness",
      usage: "lemon channels [options]",
      subcommands: [],
      options: [
        option("--project-dir PATH", ["--project-dir"], "Project root to scan"),
        option("--json", ["--json"], "Emit redacted readiness JSON")
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
          ~w(list search show history title pin unpin archive restore export prune delete)
        ),
      options: [
        option("--json", ["--json"], "Emit one redacted JSON document"),
        option("--limit N", ["--limit"], "Bound rows or history entries"),
        option("--offset N", ["--offset"], "Skip list/search rows"),
        option("--agent-id ID", ["--agent-id"], "Filter by agent id"),
        option("--pinned | --unpinned", ["--pinned", "--unpinned"], "Filter pin state"),
        option("--archived | --active", ["--archived", "--active"], "Filter archive state"),
        option("--format json|markdown", ["--format"], "Redacted export format"),
        option("--clear", ["--clear"], "Clear a session title"),
        option("--output PATH", ["--output"], "Write export content to a private file"),
        option("--force", ["--force"], "Replace an existing regular export file"),
        option("--older-than AGE|DATE", ["--older-than"], "Prune cutoff, for example 30d"),
        option("--all", ["--all"], "Allow non-archived prune candidates"),
        option("--include-pinned", ["--include-pinned"], "Allow pinned prune candidates"),
        option("--confirm TOKEN", ["--confirm"], "Exact preview or delete confirmation")
      ],
      details: [
        "History and exports are always redacted. Prune previews by default and executes only with the exact token from an unchanged candidate set. Delete requires the exact session key."
      ]
    },
    %{
      name: "completion",
      summary: "Generate shell completion scripts",
      usage: "lemon completion <bash|zsh|fish>",
      subcommands: subcommands(~w(bash zsh fish)),
      options: [],
      details: [
        "The generated script matches the source or packaged launcher that produced it. Source and release-only commands are never mixed."
      ]
    }
  ]

  @source_launcher_commands [
    launcher("web", "Open the local Web UI"),
    launcher("send", "Send a channel notification"),
    launcher("node", "Manage named execution nodes", ["join"]),
    launcher("media", "Inspect media capabilities"),
    launcher("models", "List available models"),
    launcher("policy", "Manage model policy"),
    launcher("proofs", "Inspect proof artifacts"),
    launcher("readiness", "Inspect launch readiness"),
    launcher("skill", "Manage skills"),
    launcher("usage", "Inspect usage diagnostics"),
    launcher("update", "Check for or apply updates")
  ]

  @release_launcher_commands [
    launcher("tui", "Launch the terminal UI"),
    launcher("web", "Open the local Web UI"),
    launcher("start", "Run the release in the foreground"),
    launcher("daemon", "Run the release in the background"),
    launcher("stop", "Stop the running daemon"),
    launcher("restart", "Restart the running daemon"),
    launcher("status", "Report daemon health"),
    launcher("remote", "Attach a remote IEx shell"),
    launcher("eval", "Evaluate code in a fresh release VM"),
    launcher("rpc", "Evaluate code on the running node"),
    launcher("version", "Print the installed Lemon version"),
    launcher("update", "Check for or apply updates")
  ]

  @spec commands() :: [map()]
  def commands, do: @commands

  @spec names() :: [String.t()]
  def names, do: Enum.map(@commands, & &1.name)

  @spec command?(String.t()) :: boolean()
  def command?(name) when is_binary(name), do: name in names()

  @spec fetch(String.t()) :: {:ok, map()} | :error
  def fetch(name) when is_binary(name) do
    case Enum.find(@commands, &(&1.name == name)) do
      nil -> :error
      command -> {:ok, command}
    end
  end

  @spec launcher_commands(:source | :release) :: [map()]
  def launcher_commands(:source), do: @source_launcher_commands
  def launcher_commands(:release), do: @release_launcher_commands

  @spec completion_commands(:source | :release) :: [map()]
  def completion_commands(launcher) do
    (@commands ++ launcher_commands(launcher))
    |> Enum.uniq_by(& &1.name)
    |> Enum.sort_by(& &1.name)
  end

  @spec help() :: String.t()
  def help do
    command_lines =
      @commands
      |> Enum.map(fn command ->
        "  #{String.pad_trailing(command.name, 12)} #{command.summary}"
      end)
      |> Enum.join("\n")

    """
    Usage: lemon <command> [options]

    Commands:
    #{command_lines}

    Run `lemon <command> --help` for command options.
    """
  end

  @spec help(String.t()) :: String.t()
  def help(name) do
    case fetch(name) do
      {:ok, command} -> render_help(command)
      :error -> help()
    end
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
