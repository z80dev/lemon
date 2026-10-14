defmodule LemonCli.SessionsCommand do
  @moduledoc """
  Mix-free, authenticated daemon client for durable session management.

  Every read is bounded, history/export output stays redacted, destructive
  pruning is preview-token bound, and single-session deletion requires the
  exact session key before the lifecycle service performs verified deletion.
  """

  alias LemonCli.CommandRegistry
  alias LemonCli.SessionClient

  @exit_ok 0
  @exit_error 1
  @exit_usage 2
  @max_list_limit 500
  @max_history_limit 200
  @max_query_bytes 512

  @spec run([String.t()]) :: 0 | 1 | 2
  def run(args) do
    dispatch(args)
  rescue
    error in SessionClient.Error -> failure(error.kind, error.message, json_requested?(args))
  end

  defp dispatch(["list" | args]), do: list(args, nil)
  defp dispatch(["search" | args]), do: search(args)
  defp dispatch(["stats" | args]), do: stats(args)
  defp dispatch(["show" | args]), do: show(args)
  defp dispatch(["history" | args]), do: history(args)
  defp dispatch(["context" | args]), do: context(args)
  defp dispatch(["title" | args]), do: title(args)
  defp dispatch(["pin" | args]), do: patch_boolean(args, :pinned, true, "pinned")
  defp dispatch(["unpin" | args]), do: patch_boolean(args, :pinned, false, "unpinned")
  defp dispatch(["archive" | args]), do: patch_boolean(args, :archived, true, "archived")
  defp dispatch(["restore" | args]), do: patch_boolean(args, :archived, false, "restored")
  defp dispatch(["export" | args]), do: export(args)
  defp dispatch(["prune" | args]), do: prune(args)
  defp dispatch(["delete" | args]), do: delete(args)
  defp dispatch(_args), do: usage_error("Missing or invalid sessions command.")

  defp stats(args) do
    with {:ok, parsed} <- parse_stats_options(args),
         {:ok, query} <- optional_query(parsed.positionals),
         {:ok, group_limit} <-
           bounded_option(parsed.options[:group_limit], 10, 1, 50, "group limit"),
         {:ok, pinned} <- paired_filter(parsed.options, :pinned, :unpinned),
         {:ok, archived} <- paired_filter(parsed.options, :archived, :active),
         :ok <- ensure_started(),
         {:ok, report} <-
           SessionClient.stats(
             query: query,
             agent_id: parsed.options[:agent_id],
             pinned: pinned,
             archived: archived,
             group_limit: group_limit
           ) do
      if parsed.options[:json], do: json_success(%{stats: report}), else: print_stats(report)
      @exit_ok
    else
      {:error, message} when is_binary(message) ->
        usage_error(message)
    end
  end

  defp parse_stats_options(args) do
    parse(args,
      group_limit: :integer,
      agent_id: :string,
      pinned: :boolean,
      unpinned: :boolean,
      archived: :boolean,
      active: :boolean,
      json: :boolean
    )
  end

  defp optional_query([]), do: {:ok, nil}

  defp optional_query(parts) do
    query = Enum.join(parts, " ")

    case validate_query(query) do
      :ok -> {:ok, query}
      {:error, message} -> {:error, message}
    end
  end

  defp search(args) do
    with {:ok, parsed} <- parse_list_options(args),
         [_ | _] = query_parts <- parsed.positionals,
         query <- Enum.join(query_parts, " "),
         :ok <- validate_query(query) do
      list_from_parsed(%{parsed | positionals: []}, query)
    else
      [] -> usage_error("Search requires a query.")
      {:error, message} -> usage_error(message)
    end
  end

  defp list(args, query) do
    with {:ok, parsed} <- parse_list_options(args),
         [] <- parsed.positionals do
      list_from_parsed(parsed, query)
    else
      [_ | _] -> usage_error("List does not accept positional arguments; use sessions search.")
      {:error, message} -> usage_error(message)
    end
  end

  defp list_from_parsed(parsed, query) do
    with {:ok, limit} <- bounded_option(parsed.options[:limit], 100, 1, @max_list_limit, "limit"),
         {:ok, offset} <- bounded_option(parsed.options[:offset], 0, 0, 1_000_000, "offset"),
         {:ok, pinned} <- paired_filter(parsed.options, :pinned, :unpinned),
         {:ok, archived} <- paired_filter(parsed.options, :archived, :active),
         :ok <- ensure_started() do
      result =
        SessionClient.list(
          limit: limit,
          offset: offset,
          query: query,
          agent_id: parsed.options[:agent_id],
          pinned: pinned,
          archived: archived
        )

      if parsed.options[:json] do
        json_success(%{sessions: result.sessions, matched: result.matched, total: result.total})
      else
        print_session_list(result)
      end

      @exit_ok
    else
      {:error, message} -> usage_error(message)
    end
  end

  defp parse_list_options(args) do
    parse(args,
      limit: :integer,
      offset: :integer,
      agent_id: :string,
      pinned: :boolean,
      unpinned: :boolean,
      archived: :boolean,
      active: :boolean,
      json: :boolean
    )
  end

  defp show(args) do
    with {:ok, parsed} <- parse(args, json: :boolean),
         [session_key] <- parsed.positionals,
         :ok <- ensure_started(),
         %{} = session <- SessionClient.get(session_key) do
      if parsed.options[:json],
        do: json_success(%{session: session}),
        else: print_session(session)

      @exit_ok
    else
      {:error, message} -> usage_error(message)
      nil -> failure("session_not_found", "Session not found.", json_requested?(args))
      _ -> usage_error("Show requires exactly one session key.")
    end
  end

  defp history(args) do
    with {:ok, parsed} <- parse(args, limit: :integer, json: :boolean),
         [session_key] <- parsed.positionals,
         {:ok, limit} <-
           bounded_option(parsed.options[:limit], 50, 1, @max_history_limit, "limit"),
         :ok <- ensure_started(),
         %{} = session <- SessionClient.get(session_key) do
      history = SessionClient.history(session_key, limit: limit, redact: true)

      if parsed.options[:json] do
        json_success(%{session: session, history: history, redacted: true})
      else
        print_history(session, history)
      end

      @exit_ok
    else
      {:error, message} -> usage_error(message)
      nil -> failure("session_not_found", "Session not found.", json_requested?(args))
      _ -> usage_error("History requires exactly one session key.")
    end
  end

  defp context(args) do
    with {:ok, parsed} <- parse(args, cwd: :string, json: :boolean),
         [session_key] <- parsed.positionals,
         :ok <- ensure_started() do
      cwd = Path.expand(parsed.options[:cwd] || File.cwd!())
      json? = parsed.options[:json] == true

      case SessionClient.context(session_key, cwd) do
        {:ok, report} ->
          if json?, do: json_success(%{context: report}), else: print_context(report)
          @exit_ok

        {:error, :not_found} ->
          failure(
            "session_not_found",
            "No native context recorded for this session in #{cwd}.",
            json?
          )

        {:error, :unavailable} ->
          failure("context_unavailable", "Context usage is not available yet.", json?)
      end
    else
      {:error, message} -> usage_error(message)
      _ -> usage_error("Context requires exactly one session key.")
    end
  end

  defp title(args) do
    with {:ok, parsed} <- parse(args, clear: :boolean, json: :boolean),
         {:ok, session_key, value} <- title_arguments(parsed),
         :ok <- ensure_started() do
      mutation_result(
        SessionClient.patch(session_key, %{title: value}),
        "title updated",
        parsed
      )
    else
      {:error, message} -> usage_error(message)
    end
  end

  defp title_arguments(%{positionals: [session_key], options: options}) do
    if options[:clear] do
      {:ok, session_key, nil}
    else
      {:error, "Title requires text, or pass --clear."}
    end
  end

  defp title_arguments(%{positionals: [session_key | title_parts], options: options}) do
    if options[:clear] do
      {:error, "Do not combine title text with --clear."}
    else
      title = Enum.join(title_parts, " ")

      cond do
        String.trim(title) == "" -> {:error, "Title cannot be empty; use --clear."}
        String.length(title) > 160 -> {:error, "Title must be at most 160 characters."}
        true -> {:ok, session_key, title}
      end
    end
  end

  defp title_arguments(_parsed), do: {:error, "Title requires a session key and title text."}

  defp patch_boolean(args, field, value, action) do
    with {:ok, parsed} <- parse(args, json: :boolean),
         [session_key] <- parsed.positionals,
         :ok <- ensure_started() do
      mutation_result(SessionClient.patch(session_key, %{field => value}), action, parsed)
    else
      {:error, message} -> usage_error(message)
      _ -> usage_error("This command requires exactly one session key.")
    end
  end

  defp mutation_result({:ok, session}, action, parsed) do
    if parsed.options[:json] do
      json_success(%{action: action, session: session, verified: true})
    else
      IO.puts("Session #{action}: #{session.session_key}")
    end

    @exit_ok
  end

  defp mutation_result({:error, :not_found}, _action, parsed),
    do: failure("session_not_found", "Session not found.", parsed.options[:json] == true)

  defp mutation_result({:error, _reason}, _action, parsed),
    do:
      failure(
        "session_update_failed",
        "Session metadata could not be updated safely.",
        parsed.options[:json] == true
      )

  defp export(args) do
    with {:ok, parsed} <-
           parse(args, format: :string, output: :string, force: :boolean, json: :boolean),
         [session_key] <- parsed.positionals,
         {:ok, format} <- export_format(parsed.options[:format]),
         :ok <- ensure_started(),
         {:ok, result} <- SessionClient.export(session_key, format: format),
         :ok <-
           maybe_write_export(parsed.options[:output], result.content, parsed.options[:force]) do
      print_export(result, parsed)
      @exit_ok
    else
      {:error, message} when is_binary(message) ->
        usage_error(message)

      {:error, :not_found} ->
        failure("session_not_found", "Session not found.", json_requested?(args))

      {:error, :output_exists} ->
        failure(
          "output_exists",
          "Export output already exists; pass --force to replace it.",
          json_requested?(args)
        )

      {:error, :unsafe_output} ->
        failure(
          "unsafe_output",
          "Export output must be a regular file path, not a link or special file.",
          json_requested?(args)
        )

      {:error, :write_failed} ->
        failure(
          "export_write_failed",
          "The redacted export could not be written.",
          json_requested?(args)
        )

      {:error, _reason} ->
        failure(
          "export_failed",
          "The redacted export could not be created.",
          json_requested?(args)
        )

      _ ->
        usage_error("Export requires exactly one session key.")
    end
  end

  defp export_format(nil), do: {:ok, :json}
  defp export_format("json"), do: {:ok, :json}
  defp export_format(value) when value in ["jsonl", "ndjson"], do: {:ok, :jsonl}
  defp export_format(value) when value in ["markdown", "md"], do: {:ok, :markdown}
  defp export_format("html"), do: {:ok, :html}

  defp export_format(_value),
    do: {:error, "Export format must be json, jsonl, markdown or html."}

  defp maybe_write_export(nil, _content, _force), do: :ok

  defp maybe_write_export(path, content, force?) when is_binary(path) do
    case File.lstat(path) do
      {:ok, %{type: :regular}} when force? == true -> write_export_file(path, content, false)
      {:ok, %{type: :regular}} -> {:error, :output_exists}
      {:ok, _other} -> {:error, :unsafe_output}
      {:error, :enoent} -> write_export_file(path, content, true)
      {:error, _reason} -> {:error, :write_failed}
    end
  end

  defp write_export_file(path, content, exclusive?) do
    modes = if exclusive?, do: [:write, :binary, :exclusive], else: [:write, :binary]

    with :ok <- File.mkdir_p(Path.dirname(path)),
         {:ok, :ok} <- File.open(path, modes, &IO.binwrite(&1, content)),
         :ok <- File.chmod(path, 0o600) do
      :ok
    else
      {:error, :eexist} -> {:error, :output_exists}
      _other -> {:error, :write_failed}
    end
  rescue
    _ -> {:error, :write_failed}
  end

  defp print_export(result, parsed) do
    output = parsed.options[:output]

    cond do
      parsed.options[:json] ->
        payload =
          result
          |> Map.delete(:content)
          |> Map.put(:output_file, if(output, do: Path.basename(output), else: nil))
          |> Map.put(:content, if(output, do: nil, else: result.content))

        json_success(%{export: payload})

      output ->
        IO.puts(
          "Redacted #{result.format} export written: #{Path.basename(output)} " <>
            "(#{result.bytes} bytes, sha256 #{result.sha256})"
        )

      true ->
        IO.write(result.content)
    end
  end

  defp prune(args) do
    with {:ok, parsed} <-
           parse(args,
             older_than: :string,
             all: :boolean,
             include_pinned: :boolean,
             confirm: :string,
             json: :boolean
           ),
         [] <- parsed.positionals,
         {:ok, cutoff_ms} <- parse_cutoff(parsed.options[:older_than]),
         :ok <- ensure_started() do
      opts = [
        older_than_ms: cutoff_ms,
        archived_only: parsed.options[:all] != true,
        include_pinned: parsed.options[:include_pinned] == true,
        dry_run: is_nil(parsed.options[:confirm]),
        confirm_token: parsed.options[:confirm]
      ]

      prune_result(SessionClient.prune(opts), parsed)
    else
      {:error, message} -> usage_error(message)
      [_ | _] -> usage_error("Prune does not accept positional arguments.")
    end
  end

  defp prune_result({:ok, result}, parsed) do
    if parsed.options[:json], do: json_success(%{prune: result}), else: print_prune(result)
    @exit_ok
  end

  defp prune_result({:error, :confirmation_mismatch}, parsed),
    do:
      failure(
        "confirmation_mismatch",
        "The prune candidate set changed; run the preview again and use its new token.",
        parsed.options[:json] == true
      )

  defp prune_result({:error, :confirmation_required}, parsed),
    do:
      failure(
        "confirmation_required",
        "Run the prune preview and pass its exact token with --confirm.",
        parsed.options[:json] == true
      )

  defp prune_result({:error, {:partial_failure, result}}, parsed) do
    if parsed.options[:json] do
      json_failure("partial_prune_failure", "Some sessions could not be deleted safely.", %{
        prune: result
      })
    else
      IO.puts(:stderr, "Prune stopped with verified partial failures; run a fresh preview.")
    end

    @exit_error
  end

  defp prune_result({:error, _reason}, parsed),
    do:
      failure(
        "prune_failed",
        "Sessions could not be pruned safely.",
        parsed.options[:json] == true
      )

  defp delete(args) do
    with {:ok, parsed} <- parse(args, confirm: :string, json: :boolean),
         [session_key] <- parsed.positionals,
         :ok <- exact_delete_confirmation(session_key, parsed.options[:confirm]),
         :ok <- ensure_started() do
      case SessionClient.delete(session_key) do
        {:ok, result} ->
          if parsed.options[:json] do
            json_success(%{delete: result})
          else
            IO.puts("Session deletion verified: #{session_key} (existed=#{result.existed})")
          end

          @exit_ok

        {:error, _reason} ->
          failure(
            "delete_not_verified",
            "Session deletion could not be verified; recoverable metadata was restored.",
            parsed.options[:json] == true
          )
      end
    else
      {:error, message} ->
        usage_error(message)

      _ ->
        usage_error("Delete requires exactly one session key and --confirm with that exact key.")
    end
  end

  defp exact_delete_confirmation(_session_key, nil),
    do: {:error, "Delete requires --confirm with the exact session key."}

  defp exact_delete_confirmation(session_key, session_key), do: :ok

  defp exact_delete_confirmation(_session_key, _confirm),
    do: {:error, "Delete confirmation did not match the exact session key."}

  defp parse(args, strict) do
    {options, positionals, invalid} = OptionParser.parse(args, strict: strict)

    if invalid == [] do
      {:ok, %{options: options, positionals: positionals}}
    else
      {:error, "Invalid sessions options."}
    end
  end

  defp bounded_option(nil, default, _min, _max, _label), do: {:ok, default}

  defp bounded_option(value, _default, min, max, _label)
       when is_integer(value) and value >= min and value <= max,
       do: {:ok, value}

  defp bounded_option(_value, _default, min, max, label),
    do: {:error, "#{String.capitalize(label)} must be between #{min} and #{max}."}

  defp paired_filter(options, positive, negative) do
    case {options[positive] == true, options[negative] == true} do
      {true, true} -> {:error, "Do not combine --#{positive} and --#{negative}."}
      {true, false} -> {:ok, true}
      {false, true} -> {:ok, false}
      {false, false} -> {:ok, :all}
    end
  end

  defp validate_query(query) do
    cond do
      String.trim(query) == "" -> {:error, "Search requires a non-empty query."}
      byte_size(query) > @max_query_bytes -> {:error, "Search query is too long."}
      true -> :ok
    end
  end

  defp parse_cutoff(nil), do: {:error, "Prune requires --older-than AGE|DATE."}

  defp parse_cutoff(value) do
    value = String.trim(value)

    case Regex.run(~r/^(\d+)([smhdw])$/, value) do
      [_, amount, unit] -> duration_cutoff(amount, unit)
      nil -> absolute_cutoff(value)
    end
  end

  defp duration_cutoff(amount, unit) do
    multipliers = %{
      "s" => 1_000,
      "m" => 60_000,
      "h" => 3_600_000,
      "d" => 86_400_000,
      "w" => 604_800_000
    }

    with {count, ""} when count > 0 <- Integer.parse(amount),
         duration when duration > 0 <- count * Map.fetch!(multipliers, unit),
         cutoff when cutoff > 0 <- System.system_time(:millisecond) - duration do
      {:ok, cutoff}
    else
      _ -> {:error, "Older-than age must be positive and resolve after the Unix epoch."}
    end
  end

  defp absolute_cutoff(value) do
    with :error <- integer_cutoff(value),
         {:error, _reason} <- datetime_cutoff(value),
         {:error, _reason} <- date_cutoff(value) do
      {:error, "Older-than must be an age such as 30d, epoch milliseconds, or an ISO-8601 date."}
    else
      {:ok, cutoff} -> validate_absolute_cutoff(cutoff)
    end
  end

  defp integer_cutoff(value) do
    case Integer.parse(value) do
      {cutoff, ""} when cutoff > 0 -> {:ok, cutoff}
      _ -> :error
    end
  end

  defp datetime_cutoff(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> {:ok, DateTime.to_unix(datetime, :millisecond)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp date_cutoff(value) do
    with {:ok, date} <- Date.from_iso8601(value),
         {:ok, datetime} <- DateTime.new(date, ~T[00:00:00], "Etc/UTC") do
      {:ok, DateTime.to_unix(datetime, :millisecond)}
    end
  end

  defp validate_absolute_cutoff(cutoff) do
    if cutoff <= System.system_time(:millisecond),
      do: {:ok, cutoff},
      else: {:error, "Older-than cutoff cannot be in the future."}
  end

  defp ensure_started, do: SessionClient.ensure_running()

  defp print_session_list(result) do
    IO.puts(
      "Sessions: showing #{length(result.sessions)} of #{result.matched} matched (#{result.total} total)"
    )

    if result.sessions == [] do
      IO.puts("No sessions matched.")
    else
      Enum.each(result.sessions, fn session ->
        flags =
          [
            if(session.pinned, do: "pinned", else: nil),
            if(session.archived, do: "archived", else: nil)
          ]
          |> Enum.reject(&is_nil/1)
          |> case do
            [] -> "active"
            values -> Enum.join(values, ",")
          end

        title = if session.title, do: " — #{single_line(session.title)}", else: ""

        IO.puts(
          "  #{session.session_key}  #{flags}  runs=#{session.run_count}  updated=#{format_time(session.updated_at_ms)}#{title}"
        )
      end)
    end
  end

  defp print_session(session) do
    IO.puts("Session: #{session.session_key}")
    IO.puts("Title: #{session.title || "(untitled)"}")
    IO.puts("Agent: #{session.agent_id || "unknown"}")
    IO.puts("Origin: #{session.origin}")
    IO.puts("Runs: #{session.run_count}")
    IO.puts("Pinned: #{session.pinned}")
    IO.puts("Archived: #{session.archived}")
    IO.puts("Created: #{format_time(session.created_at_ms)}")
    IO.puts("Updated: #{format_time(session.updated_at_ms)}")
  end

  defp print_stats(report) do
    totals = report.totals

    IO.puts("Redacted session statistics")

    IO.puts(
      "Sessions: #{totals.matched_sessions} matched of #{totals.store_sessions} stored " <>
        "(#{totals.active_sessions} active, #{totals.archived_sessions} archived, " <>
        "#{totals.pinned_sessions} pinned)"
    )

    IO.puts("Runs: #{totals.runs}")
    print_breakdown("Agents", report.breakdowns.agents)
    print_breakdown("Origins", report.breakdowns.origins)
  end

  defp print_breakdown(label, breakdown) do
    values =
      breakdown.entries
      |> Enum.map_join(", ", fn entry -> "#{entry.value}=#{entry.count}" end)
      |> case do
        "" -> "none"
        present -> present
      end

    suffix = if breakdown.omitted > 0, do: " (+#{breakdown.omitted} more)", else: ""
    IO.puts("#{label}: #{values}#{suffix}")
  end

  @context_bar_cells 40

  defp print_context(report) do
    window = report["window"]
    used = report["usedTokens"]
    model = get_in(report, ["model", "id"]) || "unknown model"

    size =
      if window,
        do: "#{tokens(used)} / #{tokens(window)} tokens (#{report["percentUsed"]}%)",
        else: "#{tokens(used)} tokens (window unknown)"

    IO.puts("Context usage: #{report["sessionKey"]}")
    IO.puts("Model: #{model}  #{size}  [#{context_source(report["source"])}]")

    if window do
      filled = min(round(used * @context_bar_cells / window), @context_bar_cells)

      IO.puts(
        "[" <>
          String.duplicate("#", filled) <>
          String.duplicate(".", @context_bar_cells - filled) <> "]"
      )
    end

    IO.puts("")

    rows =
      Enum.map(report["categories"], &{&1["label"], &1["tokens"], &1["percent"]}) ++
        if(report["freeTokens"],
          do: [{"Free space", report["freeTokens"], percent_of(report["freeTokens"], window)}],
          else: []
        )

    width = rows |> Enum.map(fn {label, _, _} -> String.length(label) end) |> Enum.max()

    Enum.each(rows, fn {label, count, percent} ->
      IO.puts(
        "  " <>
          String.pad_trailing(label, width) <>
          "  " <>
          String.pad_leading(tokens(count), 8) <>
          "  " <> String.pad_leading(if(percent, do: "#{percent}%", else: "-"), 6)
      )
    end)

    case report["autoCompaction"] do
      %{"enabled" => true} = budget ->
        IO.puts(
          "\nAuto-compaction at #{tokens(budget["thresholdTokens"])} tokens " <>
            "(#{tokens(budget["headroomTokens"])} headroom)."
        )

      %{"enabled" => false} ->
        IO.puts("\nAuto-compaction is disabled.")

      _ ->
        :ok
    end

    if report["top"] != [] do
      IO.puts("\nLargest contributors:")

      report["top"]
      |> Enum.with_index(1)
      |> Enum.each(fn {item, index} ->
        IO.puts("  #{index}. #{item["label"]}  #{tokens(item["tokens"])}")
      end)
    end

    IO.puts("\n" <> context_caveat(report))
  end

  defp context_source("usage"), do: "provider-reported"
  defp context_source("usage+estimate"), do: "reported + estimated"
  defp context_source(_), do: "estimated"

  defp context_caveat(report) do
    split =
      if report["source"] == "estimate",
        do: "Counts are estimates (~4 characters per token).",
        else:
          "Category splits are estimates (~4 characters per token) scaled to the reported total."

    case report["overhead"] do
      "snapshot" -> split <> " System prompt and tools were measured when the last turn ended."
      "unavailable" -> split <> " System prompt and tools are not itemized for this session yet."
      _ -> split
    end
  end

  defp percent_of(_count, nil), do: nil
  defp percent_of(count, window), do: Float.round(count * 100 / window, 1)

  defp tokens(count) when is_integer(count) and count >= 1_000_000,
    do: "#{Float.round(count / 1_000_000, 1)}M"

  defp tokens(count) when is_integer(count) and count >= 1_000,
    do: "#{Float.round(count / 1_000, 1)}k"

  defp tokens(count), do: "#{count}"

  defp print_history(session, []) do
    IO.puts("No recorded runs for #{session.session_key}.")
  end

  defp print_history(session, history) do
    IO.puts("Redacted history for #{session.session_key}: #{length(history)} run(s)")

    Enum.each(history, fn run ->
      IO.puts("")

      IO.puts(
        "Run #{run.run_id}  started=#{format_time(run.started_at_ms)}  ok=#{inspect(run.ok)}"
      )

      IO.puts("Prompt: #{single_line(run.prompt || "(not recorded)")}")
      IO.puts("Answer: #{single_line(run.answer || "(not recorded)")}")
      IO.puts("Tools: #{length(run.tools)}  events=#{run.event_count}")
    end)
  end

  defp print_prune(%{dry_run: true} = result) do
    IO.puts("Prune preview: #{result.candidate_count} candidate(s)")
    IO.puts("Archived only: #{result.archived_only}")
    IO.puts("Includes pinned: #{result.include_pinned}")
    Enum.each(result.candidate_session_keys, &IO.puts("  #{&1}"))
    IO.puts("Confirmation token: #{result.confirmation_token}")

    IO.puts(
      "Execute only after review: lemon sessions prune --older-than #{result.older_than_ms} " <>
        "--confirm #{result.confirmation_token}"
    )
  end

  defp print_prune(result) do
    IO.puts("Prune deletion verified: #{result.verified}")
    IO.puts("Deleted sessions: #{result.deleted_count}")
    Enum.each(result.deleted_session_keys, &IO.puts("  #{&1}"))
  end

  defp format_time(value) when is_integer(value) do
    case DateTime.from_unix(value, :millisecond) do
      {:ok, datetime} -> DateTime.to_iso8601(datetime)
      _ -> "unknown"
    end
  end

  defp format_time(_value), do: "unknown"

  defp single_line(value) do
    value
    |> to_string()
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  defp json_requested?(args), do: "--json" in args

  defp json_success(payload) do
    IO.puts(Jason.encode!(json_safe(Map.put(payload, :ok, true)), pretty: true))
  end

  defp json_failure(code, message, extra \\ %{}) do
    payload = Map.merge(extra, %{ok: false, error: %{code: code, message: message}})
    IO.puts(:stderr, Jason.encode!(json_safe(payload), pretty: true))
  end

  defp json_safe(value) when is_map(value) do
    Map.new(value, fn {key, nested} -> {to_string(key), json_safe(nested)} end)
  end

  defp json_safe(value) when is_list(value), do: Enum.map(value, &json_safe/1)
  defp json_safe(value) when is_tuple(value), do: value |> Tuple.to_list() |> json_safe()

  defp json_safe(value) when is_atom(value) and value not in [true, false, nil],
    do: Atom.to_string(value)

  defp json_safe(value), do: value

  defp failure(code, message, true) do
    json_failure(code, message)
    @exit_error
  end

  defp failure(_code, message, false) do
    IO.puts(:stderr, message)
    @exit_error
  end

  defp usage_error(message) do
    IO.puts(:stderr, message)
    IO.puts(:stderr, "")
    IO.write(:stderr, CommandRegistry.help("sessions"))
    @exit_usage
  end
end
