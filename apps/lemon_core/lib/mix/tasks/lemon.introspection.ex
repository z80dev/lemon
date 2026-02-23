defmodule Mix.Tasks.Lemon.Introspection do
  @shortdoc "Query agent introspection events"
  @moduledoc """
  Query and display agent introspection events from the Lemon store.

  ## Usage

      mix lemon.introspection
      mix lemon.introspection --limit 50
      mix lemon.introspection --run-id <run_id>
      mix lemon.introspection --session-key <session_key>
      mix lemon.introspection --event-type tool_completed
      mix lemon.introspection --since 1h
      mix lemon.introspection --since 2026-02-23T00:00:00Z

  ## Options

    * `--run-id <id>` - Filter by run ID
    * `--session-key <key>` - Filter by session key
    * `--event-type <type>` - Filter by event type (e.g. `run_started`, `tool_completed`)
    * `--agent-id <id>` - Filter by agent ID
    * `--limit <n>` - Maximum number of events to return (default: 20)
    * `--since <value>` - Only show events after this time. Accepts:
        - Relative: `1h`, `30m`, `2d` (hours, minutes, days)
        - ISO 8601: `2026-02-23T00:00:00Z`

  ## Output

  Events are printed as a human-readable table sorted newest-first.
  """

  use Mix.Task

  @default_limit 20

  @impl true
  def run(args) do
    start_lemon_core!()

    {opts, _rest, _invalid} =
      OptionParser.parse(args,
        switches: [
          run_id: :string,
          session_key: :string,
          event_type: :string,
          agent_id: :string,
          limit: :integer,
          since: :string
        ],
        aliases: [
          r: :run_id,
          s: :session_key,
          e: :event_type,
          a: :agent_id,
          l: :limit,
          n: :since
        ]
      )

    query_opts = build_query_opts(opts)

    events = LemonCore.Introspection.list(query_opts)

    if events == [] do
      Mix.shell().info("No introspection events found.")
    else
      print_table(events)
      Mix.shell().info("")
      Mix.shell().info("#{length(events)} event(s) shown (limit: #{query_opts[:limit]})")
    end
  end

  # Build keyword list for LemonCore.Introspection.list/1
  defp build_query_opts(opts) do
    base = [limit: opts[:limit] || @default_limit]

    base
    |> maybe_put(:run_id, opts[:run_id])
    |> maybe_put(:session_key, opts[:session_key])
    |> maybe_put(:event_type, opts[:event_type])
    |> maybe_put(:agent_id, opts[:agent_id])
    |> maybe_put_since(opts[:since])
  end

  defp maybe_put(acc, _key, nil), do: acc
  defp maybe_put(acc, key, value), do: Keyword.put(acc, key, value)

  defp maybe_put_since(acc, nil), do: acc

  defp maybe_put_since(acc, since_str) do
    case parse_since(since_str) do
      {:ok, ts_ms} ->
        Keyword.put(acc, :since_ms, ts_ms)

      {:error, reason} ->
        Mix.shell().error("Invalid --since value #{inspect(since_str)}: #{reason}")
        acc
    end
  end

  # Parse a relative duration ("1h", "30m", "2d") or ISO 8601 string to ms timestamp.
  defp parse_since(value) do
    cond do
      String.match?(value, ~r/^\d+h$/) ->
        hours = value |> String.trim_trailing("h") |> String.to_integer()
        {:ok, System.system_time(:millisecond) - hours * 60 * 60 * 1000}

      String.match?(value, ~r/^\d+m$/) ->
        minutes = value |> String.trim_trailing("m") |> String.to_integer()
        {:ok, System.system_time(:millisecond) - minutes * 60 * 1000}

      String.match?(value, ~r/^\d+d$/) ->
        days = value |> String.trim_trailing("d") |> String.to_integer()
        {:ok, System.system_time(:millisecond) - days * 24 * 60 * 60 * 1000}

      true ->
        parse_iso8601_to_ms(value)
    end
  end

  defp parse_iso8601_to_ms(value) do
    case DateTime.from_iso8601(value) do
      {:ok, dt, _offset} ->
        {:ok, DateTime.to_unix(dt, :millisecond)}

      {:error, _} ->
        {:error, "expected ISO 8601 (e.g. 2026-02-23T00:00:00Z) or relative (e.g. 1h, 30m, 2d)"}
    end
  end

  # Table rendering

  defp print_table(events) do
    col_widths = compute_col_widths(events)
    print_header(col_widths)
    Enum.each(events, fn event -> print_row(event, col_widths) end)
  end

  defp col_names,
    do: [:ts, :event_type, :run_id, :session_key, :agent_id, :engine, :provenance]

  defp compute_col_widths(events) do
    headers = %{
      ts: String.length("Timestamp"),
      event_type: String.length("Event Type"),
      run_id: String.length("Run ID"),
      session_key: String.length("Session Key"),
      agent_id: String.length("Agent ID"),
      engine: String.length("Engine"),
      provenance: String.length("Provenance")
    }

    Enum.reduce(events, headers, fn event, widths ->
      row = event_to_row(event)

      Enum.reduce(col_names(), widths, fn col, acc ->
        Map.update!(acc, col, fn w -> max(w, String.length(row[col])) end)
      end)
    end)
  end

  defp print_header(col_widths) do
    header_cols = %{
      ts: "Timestamp",
      event_type: "Event Type",
      run_id: "Run ID",
      session_key: "Session Key",
      agent_id: "Agent ID",
      engine: "Engine",
      provenance: "Provenance"
    }

    row = format_row(header_cols, col_widths)
    Mix.shell().info(row)
    separator = col_names() |> Enum.map(fn c -> String.duplicate("-", col_widths[c]) end) |> Enum.join("-+-")
    Mix.shell().info(separator)
  end

  defp print_row(event, col_widths) do
    row = event_to_row(event)
    Mix.shell().info(format_row(row, col_widths))
  end

  defp format_row(row_map, col_widths) do
    col_names()
    |> Enum.map(fn col ->
      String.pad_trailing(row_map[col], col_widths[col])
    end)
    |> Enum.join(" | ")
  end

  defp event_to_row(event) do
    %{
      ts: format_timestamp(event[:ts_ms] || event["ts_ms"]),
      event_type: to_string(event[:event_type] || event["event_type"] || ""),
      run_id: truncate(event[:run_id] || event["run_id"], 16),
      session_key: truncate(event[:session_key] || event["session_key"], 24),
      agent_id: truncate(event[:agent_id] || event["agent_id"], 16),
      engine: to_string(event[:engine] || event["engine"] || ""),
      provenance: to_string(event[:provenance] || event["provenance"] || "")
    }
  end

  defp format_timestamp(nil), do: ""

  defp format_timestamp(ts_ms) when is_integer(ts_ms) do
    case DateTime.from_unix(ts_ms, :millisecond) do
      {:ok, dt} -> Calendar.strftime(dt, "%Y-%m-%d %H:%M:%S")
      _ -> to_string(ts_ms)
    end
  end

  defp truncate(nil, _max), do: ""

  defp truncate(value, max) when is_binary(value) do
    if String.length(value) > max do
      String.slice(value, 0, max - 1) <> "~"
    else
      value
    end
  end

  defp truncate(value, _max), do: to_string(value)

  defp start_lemon_core! do
    Mix.Task.run("loadpaths")

    case Application.ensure_all_started(:lemon_core) do
      {:ok, _} -> :ok
      {:error, {app, reason}} -> Mix.raise("Failed to start #{app}: #{inspect(reason)}")
    end
  end
end
