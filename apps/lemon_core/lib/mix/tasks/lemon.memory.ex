defmodule Mix.Tasks.Lemon.Memory do
  use Mix.Task

  @shortdoc "Manage the durable memory store (stats / prune / erase)"
  @moduledoc """
  Manage the durable memory store.

  ## Subcommands

      mix lemon.memory stats
        Show total document count, oldest/newest timestamps, and config.

      mix lemon.memory prune
        Enforce retention window and max-per-scope limits.
        Deletes documents older than retention_ms and trims any session
        exceeding max_per_scope documents.

      mix lemon.memory erase --scope <session|agent|workspace> --key <value>
        Erase all memory documents for a given scope key.
        Does NOT affect run history (run_history.sqlite3 is separate).

  ## Memory vs Run History

  Lemon maintains two separate stores:

  - **memory.sqlite3** — compact, normalized summaries of finalized runs.
    Used for `search_memory` retrieval, cross-session context, and routing
    feedback (M6). Managed by `LemonCore.MemoryStore`. This is what this
    task manages.

  - **run_history.sqlite3** — full run data (messages, events, tool calls).
    Used for session replay and compaction. Managed by
    `LemonCore.RunHistoryStore`. Use `mix lemon.cleanup` to prune old runs.

  Erasing memory documents does not affect run history, and vice versa.
  """

  @impl true
  def run(args) do
    {opts, rest, _invalid} =
      OptionParser.parse(args,
        switches: [scope: :string, key: :string],
        aliases: [s: :scope, k: :key]
      )

    case rest do
      ["stats"] -> run_stats()
      ["prune"] -> run_prune()
      ["erase"] -> run_erase(opts)
      _ -> Mix.shell().info(@moduledoc)
    end
  end

  # ── Subcommands ────────────────────────────────────────────────────────────────

  defp run_stats do
    Mix.Task.run("app.start")

    stats = LemonCore.MemoryStore.stats()
    config = Application.get_env(:lemon_core, LemonCore.MemoryStore, [])

    retention_days =
      Keyword.get(config, :retention_ms, 30 * 24 * 3600_000)
      |> then(&div(&1, 24 * 3600_000))

    max_per_scope = Keyword.get(config, :max_per_scope, 500)

    Mix.shell().info("Memory Store Stats")
    Mix.shell().info("==================")
    Mix.shell().info("  Total documents : #{stats.total}")
    Mix.shell().info("  Oldest document : #{format_ms(stats.oldest_ms)}")
    Mix.shell().info("  Newest document : #{format_ms(stats.newest_ms)}")
    Mix.shell().info("")
    Mix.shell().info("Config")
    Mix.shell().info("  Retention       : #{retention_days} days")
    Mix.shell().info("  Max per scope   : #{max_per_scope} documents")
  end

  defp run_prune do
    Mix.Task.run("app.start")

    Mix.shell().info("Pruning memory store...")

    case LemonCore.MemoryStore.prune() do
      {:ok, %{swept: swept, pruned: pruned}} ->
        Mix.shell().info([:green, "Done.", :reset])
        Mix.shell().info("  Documents removed (retention) : #{swept}")
        Mix.shell().info("  Documents removed (max/scope) : #{pruned}")

      {:error, reason} ->
        Mix.shell().error("Prune failed: #{inspect(reason)}")
        System.halt(1)
    end
  end

  defp run_erase(opts) do
    scope = opts[:scope]
    key = opts[:key]

    cond do
      scope not in ["session", "agent", "workspace"] ->
        Mix.shell().error("--scope must be one of: session, agent, workspace")
        System.halt(1)

      is_nil(key) or String.trim(key) == "" ->
        Mix.shell().error("--key is required")
        System.halt(1)

      true ->
        Mix.Task.run("app.start")

        Mix.shell().info("Erasing memory documents for #{scope} #{inspect(key)}...")

        case scope do
          "session" -> LemonCore.MemoryStore.delete_by_session(key)
          "agent" -> LemonCore.MemoryStore.delete_by_agent(key)
          "workspace" -> LemonCore.MemoryStore.delete_by_workspace(key)
        end

        # Give the async cast a moment to complete before we exit
        Process.sleep(200)
        Mix.shell().info([:green, "Done.", :reset])
    end
  end

  # ── Helpers ────────────────────────────────────────────────────────────────────

  defp format_ms(nil), do: "(none)"

  defp format_ms(ms) when is_integer(ms) do
    ms
    |> DateTime.from_unix!(:millisecond)
    |> Calendar.strftime("%Y-%m-%d %H:%M UTC")
  rescue
    _ -> "(invalid)"
  end
end
