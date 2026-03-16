defmodule Mix.Tasks.Lemon.Feedback do
  use Mix.Task

  @shortdoc "Inspect historical routing feedback stats"

  @moduledoc """
  Inspect and analyze routing feedback collected from past runs.

  Routing feedback records outcome and duration per task fingerprint.
  Stats are **read-only** and do not affect live routing.

  ## Subcommands

      mix lemon.feedback stats
        Store-level summary: total records, unique fingerprints, date range,
        and the configured min_sample_size threshold.

      mix lemon.feedback list
        All fingerprints with confidence annotation.

      mix lemon.feedback list --workspace KEY
        Filter by workspace key (3rd segment in fingerprint key).

      mix lemon.feedback list --family FAMILY
        Filter by task family: code, query, file_ops, chat, unknown.

      mix lemon.feedback inspect KEY
        Full aggregate for a single fingerprint key.

  ## Options

      --workspace KEY    Filter list by workspace path
      --family FAMILY    Filter list by task family
      --since DAYS       Only include entries seen in the last N days
      --verbose, -v      Extra detail

  ## Confidence levels

  Each fingerprint is annotated with a confidence level based on sample
  size and historical success rate:

      HIGH         success_rate >= 0.8 and total >= min_sample_size
      MEDIUM       success_rate >= 0.5 and total >= min_sample_size
      LOW          success_rate < 0.5  and total >= min_sample_size
      INSUFFICIENT total < min_sample_size (default: 5)

  Confidence is only meaningful at or above `min_sample_size`. Recency
  matters: stale fingerprints (from expired data) are excluded when
  `--since` is used.

  ## Notes

  Routing feedback is recorded when the `routing_feedback` feature flag is
  enabled. If no data is found, confirm the flag is on and that runs have
  been finalized.

  ## Exit codes

      0  Success.
      1  Error.
  """

  @impl true
  def run(args) do
    {opts, rest, _invalid} =
      OptionParser.parse(args,
        strict: [
          workspace: :string,
          family: :string,
          since: :integer,
          verbose: :boolean
        ],
        aliases: [v: :verbose]
      )

    Mix.Task.run("app.start")

    since_ms =
      case opts[:since] do
        nil -> nil
        days -> System.system_time(:millisecond) - days * 24 * 60 * 60 * 1000
      end

    report_opts = if since_ms, do: [since_ms: since_ms], else: []

    case rest do
      ["stats" | _] -> run_stats(opts)
      ["list" | _] -> run_list(opts, report_opts)
      ["inspect", key | _] -> run_inspect(key, opts)
      _ -> run_list(opts, report_opts)
    end
  end

  # ── Subcommand runners ────────────────────────────────────────────────────────

  defp run_stats(_opts) do
    shell = Mix.shell()

    case LemonCore.RoutingFeedbackStore.store_stats() do
      {:ok, stats} ->
        min_n = LemonCore.RoutingFeedbackStore.min_sample_size()
        shell.info("Routing Feedback Store")
        shell.info("  Total records       : #{stats.total_records}")
        shell.info("  Unique fingerprints : #{stats.unique_fingerprints}")
        shell.info("  Min sample size     : #{min_n}")

        if stats.oldest_ms do
          shell.info("  Oldest record       : #{format_ts(stats.oldest_ms)}")
          shell.info("  Newest record       : #{format_ts(stats.newest_ms)}")
        else
          shell.info("  Date range          : (no records)")
        end

      {:error, reason} ->
        Mix.raise("Failed to query routing feedback store: #{inspect(reason)}")
    end
  end

  defp run_list(opts, report_opts) do
    shell = Mix.shell()

    result =
      cond do
        ws = opts[:workspace] ->
          LemonCore.RoutingFeedbackReport.by_workspace(ws, report_opts)

        fam = opts[:family] ->
          LemonCore.RoutingFeedbackReport.by_family(fam, report_opts)

        true ->
          LemonCore.RoutingFeedbackReport.list_all(report_opts)
      end

    case result do
      {:ok, entries} ->
        shell.info(LemonCore.RoutingFeedbackReport.format(entries))

      {:error, reason} ->
        Mix.raise("Failed to list routing feedback: #{inspect(reason)}")
    end
  end

  defp run_inspect(key, opts) do
    shell = Mix.shell()
    verbose? = opts[:verbose] || false

    case LemonCore.RoutingFeedbackStore.aggregate(key) do
      {:ok, agg} ->
        rate_pct = Float.round(agg.success_rate * 100, 1)
        shell.info("Fingerprint : #{key}")
        shell.info("  Samples     : #{agg.total}")
        shell.info("  Success     : #{rate_pct}%")

        if verbose? do
          Enum.each(agg.outcomes, fn {outcome, count} ->
            shell.info("  #{outcome}: #{count}")
          end)
        end

        if agg.mean_duration_ms do
          shell.info("  Mean dur.   : #{agg.mean_duration_ms}ms")
        end

      {:insufficient_data, n} ->
        min_n = LemonCore.RoutingFeedbackStore.min_sample_size()
        shell.info("Fingerprint : #{key}")
        shell.info("  Insufficient data: #{n} sample(s) (min_sample_size=#{min_n})")

      {:error, reason} ->
        Mix.raise("Failed to inspect fingerprint: #{inspect(reason)}")
    end
  end

  # ── Helpers ───────────────────────────────────────────────────────────────────

  defp format_ts(ms) when is_integer(ms) do
    ms
    |> DateTime.from_unix!(:millisecond)
    |> DateTime.to_string()
  end

  defp format_ts(_), do: "unknown"
end
