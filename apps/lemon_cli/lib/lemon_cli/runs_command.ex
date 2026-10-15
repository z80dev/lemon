defmodule LemonCli.RunsCommand do
  @moduledoc "Read-only operator views over the running control plane."

  @run_statuses ~w(completed aborted crashed error)
  @cron_statuses ~w(pending running completed failed timeout aborted)

  def run(["show" | args]), do: show(args)
  def run(["active" | args]), do: execute(:active, args)
  def run(["list" | args]), do: execute(:recent, args)
  def run(args), do: execute(:recent, args)

  def run_cron(["runs" | args]), do: execute(:cron, args)
  def run_cron(["status" | args]), do: cron_status(args)
  def run_cron(_args), do: usage("Use lemon cron runs [options] or lemon cron status [--json].")

  defp show(args) do
    case OptionParser.parse(args, strict: [json: :boolean]) do
      {opts, [run_id], []} when byte_size(run_id) in 1..256 ->
        show_run(run_id, opts[:json] == true)

      _ ->
        usage("Use lemon runs show <runId> [--json].")
    end
  end

  defp show_run(run_id, json?) do
    case request("runs.timeline.get", %{"runId" => run_id}) do
      {:ok, %{"entries" => entries} = timeline} when is_list(entries) ->
        if json?, do: IO.puts(Jason.encode!(timeline)), else: print_timeline(timeline)
        0

      {:ok, _} ->
        failure(:invalid_response, json?)

      {:error, reason} ->
        failure(reason, json?)
    end
  end

  defp print_timeline(timeline) do
    entries = timeline["entries"]

    origin =
      case entries do
        [first | _] -> first["atMs"]
        [] -> 0
      end

    IO.puts("Run #{clean(timeline["runId"])}")

    Enum.each(entries, fn entry ->
      marker =
        case entry["ok"] do
          true -> "[ok]"
          false -> "[fail]"
          _ -> "[#{clean(entry["status"])}]"
        end

      IO.puts(
        "+#{duration(entry["atMs"] - origin)} #{marker} #{clean(entry["label"])}" <>
          " · #{clean(entry["status"])} · #{duration(entry["durationMs"])}"
      )
    end)

    usage = timeline["usage"] || %{}
    tokens = get_in(usage, ["tokens", "total"])

    if tokens,
      do:
        IO.puts(
          "Usage: #{tokens} tokens · cost USD #{cost(usage["costUsd"])} · #{clean(usage["model"])}"
        )

    if timeline["truncated"],
      do: IO.puts("Timeline truncated: showing the latest 500 entries from bounded history.")
  end

  defp cron_status(args) do
    case OptionParser.parse(args, strict: [json: :boolean]) do
      {opts, [], []} ->
        case request("cron.status", %{}) do
          {:ok, status} ->
            if opts[:json] do
              IO.puts(Jason.encode!(status))
            else
              IO.puts(
                "Cron jobs: #{status["jobCount"] || 0}, enabled: #{status["activeJobs"] || 0}, " <>
                  "failing: #{status["failingJobs"] || 0}"
              )
            end

            0

          {:error, reason} ->
            failure(reason, opts[:json] == true)
        end

      _ ->
        usage("Use lemon cron status [--json].")
    end
  end

  defp execute(kind, args) do
    with {:ok, opts} <- parse(kind, args),
         {:ok, rows} <- fetch(kind, opts) do
      rows = select(rows, opts)

      if opts[:json],
        do: IO.puts(Jason.encode!(%{runs: rows, total: length(rows)})),
        else: print(rows)

      0
    else
      {:invalid, message} -> usage(message)
      {:error, reason} -> failure(reason, "--json" in args)
    end
  end

  defp parse(kind, args) do
    switches = [limit: :integer, json: :boolean]

    switches =
      if kind == :cron,
        do: switches ++ [job: :string, status: :string, since: :string],
        else: switches ++ [session: :string, agent: :string]

    switches =
      if kind == :recent, do: switches ++ [status: :string, since: :string], else: switches

    {opts, rest, invalid} = OptionParser.parse(args, strict: switches)
    statuses = if kind == :cron, do: @cron_statuses, else: @run_statuses
    limit = opts[:limit] || 50

    cond do
      rest != [] or invalid != [] ->
        {:invalid, "Invalid command or options."}

      limit not in 1..200 ->
        {:invalid, "Limit must be between 1 and 200."}

      opts[:status] && opts[:status] not in statuses ->
        {:invalid, "Invalid status; use #{Enum.join(statuses, ", ")}."}

      Enum.any?([:session, :agent, :job], &(opts[&1] == "")) ->
        {:invalid, "Filter values must not be empty."}

      true ->
        parse_since_option(Keyword.put(opts, :limit, limit))
    end
  end

  defp parse_since_option(opts) do
    case since_ms(opts[:since]) do
      {:ok, since} -> {:ok, Keyword.put(opts, :since_ms, since)}
      error -> error
    end
  end

  @doc false
  def since_ms(value, now \\ System.system_time(:millisecond))
  def since_ms(nil, _now), do: {:ok, nil}

  def since_ms(value, now) do
    case Regex.run(~r/\A([1-9][0-9]*)(m|h|d)\z/, value) do
      [_, count, unit] ->
        multiplier = %{"m" => 60_000, "h" => 3_600_000, "d" => 86_400_000}[unit]
        {:ok, max(now - String.to_integer(count) * multiplier, 0)}

      _ ->
        {:invalid, "Since must be a positive duration such as 30m, 1h, or 2d."}
    end
  end

  defp fetch(:recent, opts) do
    rows("runs.recent.list", filters(opts), "runs")
  end

  defp fetch(:active, opts) do
    with {:ok, sessions} <- rows("sessions.active.list", filters(opts), "sessions") do
      {:ok, Enum.map(sessions, &Map.put(&1, "status", "running"))}
    end
  end

  defp fetch(:cron, opts) do
    with {:ok, ids} <- job_ids(opts[:job]) do
      Enum.reduce_while(ids, {:ok, []}, fn id, {:ok, acc} ->
        params = %{"id" => id, "limit" => opts[:limit], "includeMeta" => false}

        params =
          put_filter(params, "status", opts[:status]) |> put_filter("sinceMs", opts[:since_ms])

        case rows("cron.runs", params, "runs") do
          {:ok, runs} ->
            projected =
              Enum.map(runs, fn run ->
                Map.take(
                  run,
                  ~w(id jobId routerRunId status startedAtMs completedAtMs durationMs sessionKey agentId error)
                )
              end)

            {:cont, {:ok, select(projected ++ acc, opts)}}

          error ->
            {:halt, error}
        end
      end)
    end
  end

  defp job_ids(nil) do
    with {:ok, jobs} <- rows("cron.list", %{}, "jobs"), do: {:ok, Enum.map(jobs, & &1["id"])}
  end

  defp job_ids(id), do: {:ok, [id]}

  defp filters(opts) do
    %{"limit" => 200}
    |> put_filter("agentId", opts[:agent])
    |> put_filter("sessionKey", opts[:session])
    |> put_filter("status", opts[:status])
  end

  defp put_filter(params, _key, nil), do: params
  defp put_filter(params, key, value), do: Map.put(params, key, value)

  defp rows(method, params, key) do
    case request(method, params) do
      {:ok, %{^key => rows}} when is_list(rows) -> {:ok, rows}
      {:ok, _} -> {:error, :invalid_response}
      error -> error
    end
  end

  defp select(rows, opts) do
    rows
    |> Enum.filter(fn row ->
      (is_nil(opts[:session]) or row["sessionKey"] == opts[:session]) and
        (is_nil(opts[:agent]) or row["agentId"] == opts[:agent]) and
        (is_nil(opts[:since_ms]) or timestamp(row) >= opts[:since_ms])
    end)
    |> Enum.sort_by(&timestamp/1, :desc)
    |> Enum.take(opts[:limit])
  end

  defp timestamp(row), do: row["startedAtMs"] || row["completedAtMs"] || row["updatedAtMs"] || 0

  defp print([]), do: IO.puts("No matching runs.")

  defp print(rows) do
    IO.puts(
      "TIME (UTC)           STATUS     DURATION  MODEL                 COST USD  " <>
        "SESSION / AGENT                     RUN           TOKENS  ERROR"
    )

    Enum.each(rows, fn row ->
      cells = [
        {clock(timestamp(row)), 19},
        {row["status"], 10},
        {duration(row["durationMs"]), 9},
        {row["model"], 21},
        {cost(row["costUsd"]), 9},
        {"#{row["sessionKey"] || "-"} / #{row["agentId"] || "-"}", 35},
        {row["runId"] || row["routerRunId"] || row["id"], 13},
        {get_in(row, ["tokens", "total"]), 7},
        {row["error"], 60}
      ]

      IO.puts(
        Enum.map_join(cells, " ", fn {value, width} ->
          value |> clean() |> String.slice(0, width) |> String.pad_trailing(width)
        end)
      )
    end)
  end

  defp clock(ms) do
    case DateTime.from_unix(ms, :millisecond) do
      {:ok, time} -> Calendar.strftime(time, "%Y-%m-%d %H:%M:%S")
      _ -> "-"
    end
  end

  defp duration(ms) when is_number(ms), do: "#{Float.round(ms / 1_000, 1)}s"
  defp duration(_), do: "-"
  defp cost(value) when is_number(value), do: :erlang.float_to_binary(value / 1, decimals: 4)
  defp cost(_), do: "-"
  defp clean(nil), do: "-"

  defp clean(value),
    do:
      value
      |> to_string()
      |> LemonCore.Redact.text()
      |> String.replace(~r/[\x00-\x1f\x7f-\x9f]/u, " ")

  @doc false
  def request(method, params) do
    Application.get_env(:lemon_cli, :control_plane_client, LemonCli.ControlPlaneClient).request(
      method,
      params
    )
  end

  @doc false
  def failure(reason, json?) do
    message =
      case reason do
        {:control_plane_unavailable, _} ->
          "Runtime not running or unreachable. " <>
            "Start it with `lemon daemon` (source: `./bin/lemon daemon`)."

        _ ->
          "Control-plane query failed; no results were returned. Check runtime health and operator authentication."
      end

    if json?,
      do: IO.puts(:stderr, Jason.encode!(%{error: %{message: message}})),
      else: IO.puts(:stderr, message)

    1
  end

  defp usage(message) do
    IO.puts(:stderr, message)
    2
  end
end
