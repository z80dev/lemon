defmodule LemonCli.OmpCommand do
  @moduledoc """
  `lemon omp`: start, watch, steer and resume omp (oh-my-pi) coding-agent
  sessions through the authenticated local control plane.

  omp processes belong to the long-running runtime (`lemon_omp`); this one-shot
  client only validates arguments, calls the `omp.*` methods and prints their
  results. Text that originated in omp (titles, activity, summaries, errors) is
  untrusted and is stripped of terminal control characters before printing.

  `watch` follows the general `omp.session` event stream on one connection and
  re-reads the session every two seconds when no event arrives. Leaving `watch`
  (including Ctrl-C) never cancels the omp turn.
  """

  alias LemonCli.{CommandRegistry, LocalRuntime}

  @exit_ok 0
  @exit_error 1
  @exit_usage 2

  @max_message_bytes 16_384
  @max_limit 100
  @poll_ms 2_000
  @start_timeout_ms 60_000
  @control_timeout_ms 20_000
  @status_timeout_ms 10_000
  @terminal_statuses ~w(idle closed failed)

  @control_regex ~r/\e\[[0-9;?]*[ -\/]*[@-~]|[\x00-\x08\x0B-\x1F\x7F]/u
  @bidi_regex ~r/[\x{061C}\x{200E}\x{200F}\x{202A}-\x{202E}\x{2066}-\x{2069}]/u

  @common [json: :boolean]
  @start_options [cwd: :string, model: :string, thinking: :string, approval_mode: :string]

  @spec run([String.t()]) :: 0 | 1 | 2
  def run(args) when is_list(args) do
    case plan(args) do
      {:ok, plan, json?} ->
        case LocalRuntime.ensure_running() do
          :ok ->
            execute(plan, json?)

          {:error, message} ->
            IO.puts(:stderr, "Error: #{message}")
            @exit_error
        end

      {:error, message} ->
        usage_error(message)
    end
  end

  ## Argument parsing

  defp plan([]), do: plan(["list"])
  defp plan(["status" | args]), do: no_positionals(args, @common, &{:status, &1})

  defp plan(["list" | args]) do
    with {:ok, opts, []} <- parse(args, @common ++ [all: :boolean, limit: :integer]),
         {:ok, limit} <- limit(opts) do
      params = %{"includeEnded" => opts[:all] == true} |> put("limit", limit)
      {:ok, {:list, params}, opts[:json] == true}
    else
      {:ok, _opts, _rest} -> {:error, "list takes no positional arguments."}
      error -> error
    end
  end

  defp plan(["show" | args]), do: with_id(args, @common, &{:show, &1})
  defp plan(["cancel" | args]), do: with_id(args, @common, &{:cancel, &1})
  defp plan(["close" | args]), do: with_id(args, @common, &{:close, &1})
  defp plan(["watch" | args]), do: with_id(args, @common, &{:watch, &1})

  defp plan(["discover" | args]) do
    with {:ok, opts, []} <- parse(args, @common ++ [cwd: :string, limit: :integer]),
         {:ok, limit} <- limit(opts) do
      params = %{"cwd" => cwd(opts)} |> put("limit", limit)
      {:ok, {:discover, params}, opts[:json] == true}
    else
      {:ok, _opts, _rest} -> {:error, "discover takes no positional arguments; use --cwd."}
      error -> error
    end
  end

  defp plan(["start" | args]) do
    with {:ok, opts, words} <- parse(args, @common ++ @start_options ++ [isolate: :boolean]),
         :ok <- approval_mode(opts),
         {:ok, prompt} <- text(words, "start requires a prompt.") do
      params =
        %{"cwd" => cwd(opts), "prompt" => prompt}
        |> put("model", opts[:model])
        |> put("thinking", opts[:thinking])
        |> put("approvalMode", opts[:approval_mode])
        |> put("isolate", opts[:isolate])

      {:ok, {:start, params}, opts[:json] == true}
    end
  end

  defp plan(["resume" | args]) do
    case parse(args, @common ++ @start_options ++ [continue: :boolean]) do
      {:ok, opts, [omp_session_id | words]} ->
        with :ok <- approval_mode(opts),
             :ok <-
               exclusive(
                 opts[:continue] == true and words != [],
                 "--continue cannot accompany a prompt."
               ) do
          params =
            %{"ompSessionId" => omp_session_id, "cwd" => cwd(opts)}
            |> put("prompt", if(words == [], do: nil, else: Enum.join(words, " ")))
            |> put("model", opts[:model])
            |> put("thinking", opts[:thinking])
            |> put("approvalMode", opts[:approval_mode])
            |> put("continue", opts[:continue])

          {:ok, {:resume, params}, opts[:json] == true}
        end

      {:ok, _opts, []} ->
        {:error, "resume requires an omp session id (see `lemon omp discover`)."}

      error ->
        error
    end
  end

  defp plan(["send" | args]) do
    case parse(args, @common ++ [follow_up: :boolean, redirect: :boolean]) do
      {:ok, opts, [id | words]} ->
        with {:ok, message} <- text(words, "send requires a message."),
             :ok <- message_size(message),
             :ok <-
               exclusive(
                 opts[:follow_up] == true and opts[:redirect] == true,
                 "--follow-up and --redirect are mutually exclusive."
               ) do
          mode =
            cond do
              opts[:redirect] -> "redirect"
              opts[:follow_up] -> "followUp"
              true -> "steer"
            end

          params = %{"id" => id, "message" => message, "mode" => mode}
          {:ok, {:send, params}, opts[:json] == true}
        end

      {:ok, _opts, []} ->
        {:error, "send requires a session id and a message."}

      error ->
        error
    end
  end

  defp plan(["start-many" | args]) do
    with {:ok, opts, []} <-
           parse(args, @common ++ @start_options ++ [task: :keep, isolate: :boolean]),
         :ok <- approval_mode(opts),
         tasks = Keyword.get_values(opts, :task),
         true <- length(tasks) in 1..8 and Enum.all?(tasks, &(String.trim(&1) != "")) do
      shared =
        %{"cwd" => cwd(opts)}
        |> put("model", opts[:model])
        |> put("thinking", opts[:thinking])
        |> put("approvalMode", opts[:approval_mode])
        |> put("isolate", opts[:isolate])

      {:ok, {:start_many, %{"tasks" => Enum.map(tasks, &Map.put(shared, "prompt", &1))}},
       opts[:json] == true}
    else
      {:ok, _, _} -> {:error, "start-many takes only options; repeat --task PROMPT."}
      false -> {:error, "start-many requires 1 to 8 non-empty --task prompts."}
      error -> error
    end
  end

  defp plan(["models" | args]) do
    with {:ok, opts, words} <-
           parse(args, @common ++ [free: :boolean, provider: :string, limit: :integer]),
         {:ok, limit} <- limit(opts, 200),
         true <- length(words) <= 1 do
      params =
        %{}
        |> put("query", List.first(words))
        |> put("provider", opts[:provider])
        |> put("freeOnly", opts[:free])
        |> put("limit", limit)

      {:ok, {:models, params}, opts[:json] == true}
    else
      false -> {:error, "models accepts at most one query."}
      error -> error
    end
  end

  defp plan(["subagent" | args]) do
    with {:ok, opts, [id, subagent_id]} <- parse(args, @common ++ [limit: :integer]),
         {:ok, limit} <- limit(opts, 50) do
      {:ok, {:subagent, %{"id" => id, "subagentId" => subagent_id} |> put("limit", limit)},
       opts[:json] == true}
    else
      {:ok, _, _} -> {:error, "subagent requires a session id and subagent id."}
      error -> error
    end
  end

  defp plan(["configure" | args]) do
    with {:ok, opts, [id]} <- parse(args, @common ++ [model: :string, thinking: :string]),
         true <-
           Enum.any?([opts[:model], opts[:thinking]], &(is_binary(&1) and String.trim(&1) != "")) do
      params = %{"id" => id} |> put("model", opts[:model]) |> put("thinking", opts[:thinking])
      {:ok, {:configure, params}, opts[:json] == true}
    else
      {:ok, _, _} -> {:error, "configure requires exactly one session id."}
      false -> {:error, "configure requires --model or --thinking."}
      error -> error
    end
  end

  defp plan([command | _args]), do: {:error, "Unknown omp command: #{clean_line(command)}"}

  defp no_positionals(args, strict, build) do
    case parse(args, strict) do
      {:ok, opts, []} -> {:ok, build.(%{}), opts[:json] == true}
      {:ok, _opts, _rest} -> {:error, "This command takes no positional arguments."}
      error -> error
    end
  end

  defp with_id(args, strict, build) do
    case parse(args, strict) do
      {:ok, opts, [id]} -> {:ok, build.(%{"id" => id}), opts[:json] == true}
      {:ok, _opts, _rest} -> {:error, "This command requires exactly one session id."}
      error -> error
    end
  end

  defp parse(args, strict) do
    case OptionParser.parse(args, strict: strict) do
      {opts, rest, []} -> {:ok, opts, rest}
      {_opts, _rest, _invalid} -> {:error, "Invalid omp options."}
    end
  end

  defp limit(opts, max_limit \\ @max_limit) do
    case opts[:limit] do
      nil -> {:ok, nil}
      limit when is_integer(limit) and limit >= 1 and limit <= max_limit -> {:ok, limit}
      _limit -> {:error, "--limit must be between 1 and #{max_limit}."}
    end
  end

  defp approval_mode(opts) do
    if opts[:approval_mode] in [nil, "always-ask", "write", "yolo"],
      do: :ok,
      else: {:error, "--approval-mode must be always-ask, write, or yolo."}
  end

  defp exclusive(value, message), do: if(value, do: {:error, message}, else: :ok)

  defp text(words, message) do
    text = Enum.join(words, " ")
    if String.trim(text) == "", do: {:error, message}, else: {:ok, text}
  end

  defp message_size(message) do
    if byte_size(message) <= @max_message_bytes,
      do: :ok,
      else: {:error, "message must be at most 16 KiB."}
  end

  defp cwd(opts), do: Path.expand(opts[:cwd] || File.cwd!())

  defp put(map, _key, nil), do: map
  defp put(map, key, value), do: Map.put(map, key, value)

  ## Execution

  defp execute({:watch, %{"id" => id}}, json?), do: watch(id, json?)

  defp execute({operation, params}, json?) do
    {method, timeout_ms} = method(operation)

    case request(method, params, timeout_ms) do
      {:ok, payload} ->
        if json?,
          do: IO.puts(Jason.encode!(payload, pretty: true)),
          else: print(operation, params, payload)

        @exit_ok

      {:error, reason} ->
        operation_error(reason, params["id"], json?)
    end
  end

  defp method(:status), do: {"omp.status", @status_timeout_ms}
  defp method(:list), do: {"omp.sessions.list", 5_000}
  defp method(:show), do: {"omp.sessions.get", 5_000}
  defp method(:discover), do: {"omp.sessions.discover", 10_000}
  defp method(:start), do: {"omp.sessions.start", @start_timeout_ms}
  defp method(:resume), do: {"omp.sessions.resume", @start_timeout_ms}
  defp method(:send), do: {"omp.sessions.send", @control_timeout_ms}
  defp method(:cancel), do: {"omp.sessions.cancel", @control_timeout_ms}
  defp method(:close), do: {"omp.sessions.close", @control_timeout_ms}
  defp method(:start_many), do: {"omp.sessions.startMany", @start_timeout_ms}
  defp method(:models), do: {"omp.models", 30_000}
  defp method(:subagent), do: {"omp.sessions.subagent", @control_timeout_ms}
  defp method(:configure), do: {"omp.sessions.configure", @start_timeout_ms}

  defp request(method, params, timeout_ms),
    do: client().request(method, params, timeout_ms: timeout_ms)

  defp client,
    do: Application.get_env(:lemon_cli, :control_plane_client, LemonCli.ControlPlaneClient)

  ## Watch

  defp watch(id, json?) do
    case client().open([]) do
      {:ok, conn} ->
        try do
          case client().call(conn, "omp.sessions.get", %{"id" => id}) do
            {:ok, %{"session" => session}} ->
              unless json?,
                do: IO.puts(:stderr, "Watching #{id}; Ctrl-C stops watching without cancelling.")

              report(session, nil, json?)
              follow(conn, id, session, json?)

            {:ok, _payload} ->
              operation_error(:invalid_response, id, json?)

            {:error, reason} ->
              operation_error(call_error(reason), id, json?)
          end
        after
          client().close(conn)
        end

      {:error, reason} ->
        operation_error({:control_plane_unavailable, reason}, id, json?)
    end
  end

  defp follow(_conn, _id, %{"status" => status} = session, json?)
       when status in @terminal_statuses do
    unless json?, do: print_outcome(session)
    @exit_ok
  end

  defp follow(conn, id, session, json?) do
    case client().next_event(conn, @poll_ms) do
      {:ok, %{"event" => "omp.session", "payload" => %{"session" => %{"id" => ^id} = next}}} ->
        report(next, session, json?)
        follow(conn, id, next, json?)

      {:ok, _other_event} ->
        follow(conn, id, session, json?)

      {:error, :control_plane_timeout} ->
        case client().call(conn, "omp.sessions.get", %{"id" => id}) do
          {:ok, %{"session" => next}} ->
            report(next, session, json?)
            follow(conn, id, next, json?)

          {:error, reason} ->
            operation_error(call_error(reason), id, json?)
        end

      {:error, reason} ->
        operation_error(call_error(reason), id, json?)
    end
  end

  defp report(session, previous, true) do
    if changed?(session, previous), do: IO.puts(Jason.encode!(session))
  end

  defp report(session, previous, false) do
    if changed?(session, previous) do
      activity = session["activity"] && " — " <> clean_line(session["activity"])
      IO.puts("[#{clock(session["updatedAt"])}] #{session["status"]}#{activity}")
    end
  end

  defp changed?(_session, nil), do: true

  defp changed?(session, previous) do
    Map.take(session, ~w(status activity lastTurn)) !=
      Map.take(previous, ~w(status activity lastTurn))
  end

  defp call_error(%{} = error), do: {:control_plane, error}
  defp call_error(reason), do: reason

  ## Human output
  defp value(nil), do: "unknown"
  defp value(value), do: to_string(value)

  defp print(:status, _params, %{"available" => true} = status) do
    IO.puts("omp: available (#{clean_line(status["version"] || "version unknown")})")
    IO.puts("Live sessions: #{status["live"]}/#{status["maxSessions"]}")
  end

  defp print(:status, _params, status) do
    IO.puts("omp: not installed")
    IO.puts("Install omp or set LEMON_OMP_BIN to its executable, then restart Lemon.")
    IO.puts("Live sessions: #{status["live"] || 0}/#{status["maxSessions"] || "?"}")
  end

  defp print(:list, params, %{"sessions" => []}) do
    if params["includeEnded"],
      do: IO.puts("No omp sessions."),
      else: IO.puts("No live omp sessions (use --all to include ended ones).")
  end

  defp print(:list, _params, %{"sessions" => sessions}) do
    table(
      ["ID", "STATUS", "TURNS", "UPDATED", "TITLE"],
      Enum.map(sessions, fn session ->
        [
          session["id"],
          status_label(session),
          to_string(session["turns"] || 0),
          clock(session["updatedAt"]),
          clean_line(session["title"] || "")
        ]
      end)
    )
  end

  defp print(:show, _params, payload) do
    IO.puts(clean_text(payload["summary"] || ""))
    session = payload["session"] || %{}
    IO.puts("Approval mode: #{clean_line(session["approvalMode"] || "omp default")}")

    Enum.each(session["pendingApprovals"] || [], fn approval ->
      IO.puts(
        "Pending approval #{clean_line(approval["id"])}: #{clean_line(approval["tool"])} — #{clean_line(approval["details"])}"
      )
    end)

    if (session["pendingApprovals"] || []) != [] do
      IO.puts("Resolve pending approvals through the TUI or control-plane exec.approval.resolve.")
    end

    if worktree = session["worktree"] do
      IO.puts("Worktree: #{clean_line(worktree["path"])} (#{clean_line(worktree["branch"])})")

      IO.puts(
        "  kept: #{value(worktree["kept"])}; dirty: #{value(worktree["dirty"])}; commits: #{value(worktree["commits"])}"
      )
    end

    Enum.each(session["subagents"] || [], fn child ->
      IO.puts(
        "Subagent #{clean_line(child["id"])} [#{clean_line(child["status"])}]: #{clean_line(child["activity"] || child["description"])}"
      )
    end)
  end

  defp print(:discover, params, %{"sessions" => []}),
    do: IO.puts("No stored omp sessions for #{params["cwd"]}.")

  defp print(:discover, _params, %{"sessions" => sessions}) do
    table(
      ["OMP SESSION", "SOURCE", "LAST", "UPDATED", "LIVE", "TITLE"],
      Enum.map(sessions, fn session ->
        [
          clean_line(session["ompSessionId"] || ""),
          clean_line(session["source"] || "-"),
          clean_line(session["lastStatus"] || "") <>
            if(session["interrupted"], do: " (interrupted)", else: ""),
          date_time(session["updatedAt"]),
          session["liveId"] || if(session["activeElsewhere"], do: "elsewhere", else: "-"),
          clean_line(session["title"] || "")
        ]
      end)
    )

    IO.puts("Resume one with: lemon omp resume <omp-session> [prompt]")
  end

  defp print(operation, _params, %{"session" => session}) when operation in [:start, :resume] do
    verb = if operation == :start, do: "Started", else: "Resumed"
    IO.puts("#{verb} omp session #{session["id"]} (#{session["status"]}) in #{session["cwd"]}")
    IO.puts("Watch: lemon omp watch #{session["id"]}")
  end

  defp print(:start_many, _params, %{"results" => results}) do
    Enum.each(results, fn
      %{"index" => index, "session" => session} ->
        IO.puts("#{index}: #{clean_line(session["id"])} (#{clean_line(session["status"])})")

      %{"index" => index, "error" => error} ->
        IO.puts("#{index}: #{clean_line(error["code"])}: #{safe_message(error["message"])}")
    end)
  end

  defp print(:models, _params, %{"models" => models}) do
    table(
      ["SELECTOR", "NAME", "CONTEXT", "$IN/MTOK", "$OUT/MTOK"],
      Enum.map(models, fn model ->
        [
          clean_line(model["selector"]),
          clean_line(model["name"]),
          value(model["contextWindow"]),
          if(model["free"], do: "FREE", else: value(model["costInput"])),
          if(model["free"], do: "FREE", else: value(model["costOutput"]))
        ]
      end)
    )
  end

  defp print(:subagent, _params, %{"transcript" => %{"messages" => messages}}) do
    Enum.each(messages, fn message ->
      tool = if message["toolName"], do: " (#{clean_line(message["toolName"])})", else: ""
      IO.puts("#{clean_line(message["role"])}#{tool}: #{clean_text(message["text"])}")
    end)
  end

  defp print(:configure, _params, %{"session" => session}) do
    IO.puts(
      "Configured #{clean_line(session["id"])}: model #{clean_line(session["model"])}; thinking #{clean_line(session["thinking"])}"
    )
  end

  defp print(:send, %{"id" => id}, %{"delivery" => delivery}),
    do: IO.puts("Delivered to #{id} as #{delivery}.")

  defp print(:cancel, %{"id" => id}, _payload),
    do: IO.puts("Cancelled the running turn of #{id}; the session stays open.")

  defp print(:close, %{"id" => id}, _payload),
    do: IO.puts("Closed #{id}; resume it later with `lemon omp resume`.")

  defp print_outcome(%{"status" => "idle"} = session) do
    IO.puts("Turn #{session["lastTurn"] || "finished"}.")
    if session["result"], do: IO.puts(clean_text(session["result"]))
    if session["error"], do: IO.puts("Error: " <> clean_line(session["error"]))
  end

  defp print_outcome(session) do
    IO.puts("Session #{session["status"]}.")
    if session["error"], do: IO.puts("Error: " <> clean_line(session["error"]))
  end

  defp status_label(%{"status" => "idle", "lastTurn" => turn}) when is_binary(turn),
    do: "idle (#{turn})"

  defp status_label(session), do: to_string(session["status"])

  defp table(headers, rows) do
    widths =
      Enum.reduce(rows, Enum.map(headers, &String.length/1), fn row, widths ->
        row |> Enum.map(&String.length/1) |> Enum.zip_with(widths, &max/2)
      end)

    Enum.each([headers | rows], fn row ->
      {cells, [last]} = Enum.split(row, -1)

      line =
        cells
        |> Enum.zip(widths)
        |> Enum.map_join("  ", fn {cell, width} -> String.pad_trailing(cell, width) end)

      IO.puts(String.trim_trailing(line <> "  " <> last))
    end)
  end

  defp clock(ms) when is_integer(ms) do
    case DateTime.from_unix(ms, :millisecond) do
      {:ok, datetime} ->
        datetime |> DateTime.to_time() |> Time.truncate(:second) |> Time.to_string()

      _ ->
        "-"
    end
  end

  defp clock(_ms), do: "-"

  defp date_time(ms) when is_integer(ms) do
    case DateTime.from_unix(ms, :millisecond) do
      {:ok, datetime} -> datetime |> DateTime.truncate(:second) |> DateTime.to_iso8601()
      _ -> "-"
    end
  end

  defp date_time(_ms), do: "-"

  # omp-originated text is untrusted: drop terminal control sequences and
  # bidirectional overrides before it reaches the operator's terminal.
  defp clean_text(value) when is_binary(value) do
    value
    |> String.replace(@control_regex, "")
    |> String.replace(@bidi_regex, "")
  end

  defp clean_text(_value), do: ""

  defp clean_line(value),
    do: value |> clean_text() |> String.replace(~r/\s+/u, " ") |> String.trim()

  ## Errors

  defp operation_error(reason, id, json?) do
    {code, message, details} = safe_error(reason)
    retry_unsafe? = details["retrySafe"] == false

    if json? do
      error = %{"code" => code, "message" => message} |> put("details", non_empty(details))
      IO.puts(:stderr, Jason.encode!(%{"ok" => false, "error" => error}))
    else
      IO.puts(:stderr, "omp request failed [#{code}]: #{message}")

      if details["code"] == "OMP_PARTIALLY_APPLIED" do
        applied = Enum.map_join(details["applied"] || [], ", ", &clean_line/1)

        IO.puts(
          :stderr,
          "Applied: #{applied}. Failed step: #{clean_line(details["failedStep"])}. Earlier changes were not rolled back."
        )
      end

      if retry_unsafe? do
        hint = if id, do: "lemon omp show #{id}", else: "lemon omp list"
        IO.puts(:stderr, "Not retry-safe: check `#{hint}` before trying again.")
      end
    end

    @exit_error
  end

  defp safe_error({:control_plane, %{} = error}) do
    details = if is_map(error["details"]), do: error["details"], else: %{}

    {safe_code(error["code"]), safe_message(error["message"]),
     Map.take(details, ~w(code retrySafe id field applied failedStep))}
  end

  defp safe_error({:control_plane_unavailable, _reason}),
    do: {"CONTROL_PLANE_UNAVAILABLE", "The Lemon control plane is unavailable.", %{}}

  defp safe_error(:control_plane_timeout),
    do:
      {"CONTROL_PLANE_TIMEOUT",
       "The Lemon control plane did not answer in time; the request may still take effect.",
       %{"retrySafe" => false}}

  defp safe_error(:disconnected),
    do: {"CONTROL_PLANE_UNAVAILABLE", "The Lemon control plane connection closed.", %{}}

  defp safe_error(_reason), do: {"OPERATION_FAILED", "The omp request failed.", %{}}

  defp safe_code(code)
       when code in ~w(INVALID_REQUEST INVALID_PARAMS NOT_FOUND CONFLICT FORBIDDEN UNAUTHORIZED UNAVAILABLE TIMEOUT RATE_LIMITED INTERNAL_ERROR),
       do: code

  defp safe_code(_code), do: "OPERATION_FAILED"

  defp safe_message(message) when is_binary(message) and byte_size(message) <= 1_024 do
    case clean_line(message) do
      "" -> "The omp request failed."
      cleaned -> cleaned
    end
  end

  defp safe_message(_message), do: "The omp request failed."

  defp non_empty(map) when map == %{}, do: nil
  defp non_empty(map), do: map

  defp usage_error(message) do
    IO.puts(:stderr, message)
    IO.puts(:stderr, "")
    IO.write(:stderr, CommandRegistry.help("omp"))
    @exit_usage
  end
end
