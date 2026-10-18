defmodule LemonCore.Usage.CLI do
  @moduledoc """
  Show redacted usage, cost, token, and quota diagnostics.

  ## Usage

      lemon usage
      lemon usage --json

  ## Options

    * `--days N` - Report the last N UTC dates, including today (1–366).
    * `--since/--until YYYY-MM-DD` - Inclusive UTC date boundaries.
    * `--by day|provider|model|session` - Breakdown (default provider).
    * `--json` - Emit redacted JSON, including completeness and omissions.

  Unknown token counts and costs render as `unknown` in text and `null` in JSON;
  numeric budget estimates are not substituted for provider measurements.
  """

  alias LemonCore.UsageDiagnostics

  def run(args) do
    {opts, params} = parse_args!(args)

    LemonCore.CLI.start!(:lemon_core)

    report =
      case LemonCore.UsageReport.query(params) do
        {:ok, report} -> report
        {:error, _} -> LemonCore.CLI.fail!("Usage ledger unavailable", 1)
      end

    if Enum.any?([:days, :since, :until, :by], &Keyword.has_key?(opts, &1)) do
      if opts[:json],
        do: LemonCore.CLI.info(Jason.encode!(report, pretty: true)),
        else: print_report(report, opts[:by] || "provider")
    else
      status = Map.put(UsageDiagnostics.status(), :report, report)

      if opts[:json] do
        LemonCore.CLI.info(Jason.encode!(status, pretty: true))
      else
        print_text(status)
        print_completeness(report)
      end
    end
  end

  @doc false
  def parse_args!(args) do
    {opts, rest, invalid} =
      OptionParser.parse(args,
        strict: [json: :boolean, days: :integer, since: :string, until: :string, by: :string]
      )

    days = opts[:days] || 1
    by = opts[:by] || "provider"

    if invalid != [] or rest != [] or days < 1 or days > 366 or
         by not in ["day", "provider", "model", "session"] or
         (Keyword.has_key?(opts, :days) and
            (Keyword.has_key?(opts, :since) or Keyword.has_key?(opts, :until))) do
      LemonCore.CLI.fail!("Invalid arguments. Run `lemon usage --help`.", 2)
    end

    until = parse_date!(opts[:until], Date.utc_today())
    since = parse_date!(opts[:since], Date.add(until, 1 - days))

    if Date.compare(since, until) == :gt or Date.diff(until, since) >= 366 do
      LemonCore.CLI.fail!("Usage range must contain 1–366 days in chronological order.", 2)
    end

    {opts,
     %{
       "startDate" => Date.to_iso8601(since),
       "endDate" => Date.to_iso8601(until),
       "groupBy" => by
     }}
  end

  defp parse_date!(nil, default), do: default

  defp parse_date!(value, _default) do
    case Date.from_iso8601(value) do
      {:ok, date} -> date
      _ -> LemonCore.CLI.fail!("Expected a date in YYYY-MM-DD format.", 2)
    end
  end

  defp print_report(report, by) do
    LemonCore.CLI.info("Lemon Usage")
    LemonCore.CLI.info("Period: #{report["startDate"]} → #{report["endDate"]}")
    LemonCore.CLI.info("Requests: #{report["totalRequests"]}")
    LemonCore.CLI.info("Known cost subtotal: #{format_money(report["totalCost"])} USD")
    print_completeness(report)

    {key, label} =
      case by do
        "day" -> {"dailyUsage", "date"}
        "provider" -> {"providers", "provider"}
        "model" -> {"models", "model"}
        "session" -> {"sessions", "sessionKey"}
      end

    LemonCore.CLI.info("#{by}:")

    Enum.each(report[key], fn row ->
      name = if by == "model", do: "#{row["provider"]}:#{row[label]}", else: row[label]

      cost =
        if report["incomplete"],
          do: "known subtotal #{format_money(row["cost"])} (unknown pricing may be present)",
          else: format_money(row["cost"])

      LemonCore.CLI.info(
        "  #{name}: requests=#{display_number(row["requests"])} cost=#{cost} input_tokens=#{display_number(row["inputTokens"])} output_tokens=#{display_number(row["outputTokens"])}"
      )
    end)
  end

  defp print_completeness(report) do
    LemonCore.CLI.info("Incomplete: #{report["incomplete"]}")
    LemonCore.CLI.info("Sessions omitted: #{report["sessionsOmitted"]}")

    if report["incomplete"],
      do:
        LemonCore.CLI.info(
          "Unknown pricing or unattributed historical costs: totals are known-cost subtotals, not free execution."
        )
  end

  defp print_text(status) do
    cleanup = Map.get(status, :cleanup, %{})
    tokens = Map.get(status, :total_tokens, %{})
    today = Map.get(status, :today, %{})

    LemonCore.CLI.info("Lemon Usage")
    LemonCore.CLI.info("Status: #{Map.get(status, :status, "unknown")}")
    LemonCore.CLI.info("Period: #{Map.get(status, :period, "current")}")
    LemonCore.CLI.info("Requests: #{display_number(Map.get(status, :total_requests, 0))}")
    LemonCore.CLI.info("Cost: #{format_money(Map.get(status, :total_cost, 0.0))}")
    LemonCore.CLI.info("Tokens input: #{display_number(Map.get(tokens, :input, 0))}")
    LemonCore.CLI.info("Tokens output: #{display_number(Map.get(tokens, :output, 0))}")
    LemonCore.CLI.info("Tokens total: #{display_number(Map.get(tokens, :total, 0))}")

    LemonCore.CLI.info(
      "Today: #{Map.get(today, :date, "unknown")} requests=#{display_number(Map.get(today, :requests, 0))} cost=#{format_money(Map.get(today, :cost, 0.0))}"
    )

    LemonCore.CLI.info("Includes prompts: #{truthy?(cleanup[:includes_prompts])}")
    LemonCore.CLI.info("Includes responses: #{truthy?(cleanup[:includes_responses])}")
    LemonCore.CLI.info("Includes message bodies: #{truthy?(cleanup[:includes_message_bodies])}")
    LemonCore.CLI.info("Includes credentials: #{truthy?(cleanup[:includes_credentials])}")
    LemonCore.CLI.info("Includes secret values: #{truthy?(cleanup[:includes_secret_values])}")
    print_quotas(Map.get(status, :quotas, %{}))
    print_providers(Map.get(status, :providers, []))
  end

  defp print_quotas(quotas) do
    LemonCore.CLI.info("Quotas:")
    LemonCore.CLI.info("  runs_limit: #{display_limit(quotas[:runs_limit])}")
    LemonCore.CLI.info("  tokens_limit: #{display_limit(quotas[:tokens_limit])}")
    LemonCore.CLI.info("  cost_limit: #{display_limit(quotas[:cost_limit])}")
  end

  defp print_providers([]) do
    LemonCore.CLI.info("Providers: none")
  end

  defp print_providers(providers) do
    LemonCore.CLI.info("Providers:")

    Enum.each(providers, fn provider ->
      LemonCore.CLI.info(
        "  #{provider.provider}: requests=#{display_number(provider.requests)} cost=#{format_money(provider.cost)} input_tokens=#{display_number(provider.input_tokens)} output_tokens=#{display_number(provider.output_tokens)}"
      )
    end)
  end

  defp display_limit(nil), do: "unlimited"
  defp display_limit(limit), do: to_string(limit)

  defp format_money(value) when is_number(value),
    do: :erlang.float_to_binary(value * 1.0, decimals: 4)

  defp format_money(_), do: "unknown"

  defp display_number(value) when is_number(value), do: to_string(value)
  defp display_number(_), do: "unknown"

  defp truthy?(value), do: if(value, do: "true", else: "false")
end
