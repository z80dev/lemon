defmodule Mix.Tasks.Lemon.Honcho do
  use Mix.Task

  @shortdoc "Inspect the Honcho memory satellite (status / sessions / ping / context)"
  @moduledoc """
  Inspect the Honcho memory satellite from the command line.

  ## Subcommands

      mix lemon.honcho status [--timeout MS]
        Show the resolved configuration, then probe whether Honcho answers.

      mix lemon.honcho sessions
        List the Lemon session keys *this* node has mapped to Honcho sessions.
        Reads process state only and never touches the network.

      mix lemon.honcho ping [--timeout MS]
        Round-trip one request to Honcho and report the latency in ms.
        Exits non-zero when the round trip fails, so it is usable in a script.

      mix lemon.honcho context [--session KEY] [--query TEXT] [--live]
        Explain what *this* node would inject for a session. Read-only by
        default; `--live` assembles the block for real, which is not.

  ## This task runs in its own node

  Every subcommand starts the umbrella with `Mix.Task.run("app.start")`, in the
  node `mix` is running. That node is never a Lemon already serving on this
  machine, and the distinction decides what an answer here is worth.

  `status` and `ping` transfer, because what they answer does not depend on which
  node asks: `status` resolves the configuration out of the environment this
  command inherits, and `ping` makes one real request to Honcho. `sessions` and
  `context` do not: they read `LemonHoncho.SessionManager` *in this node*, which
  has served no turns, so a healthy install still prints an empty session list
  and an untracked session. They are honest about this node; they are not a
  window into another one. To see what a running Lemon holds, ask it — the
  assistant's own answers are the observable — or drive the manager in-process,
  which is what `--live` does here.

  Booting also has costs of its own. HTTP listeners bind, a configured Discord
  bot connects a second shard, and start-up work such as an API token refresh
  runs, as a side effect of asking for status. Where Lemon is already running
  the listeners are already bound, and this task exits with `:eaddrinuse`
  without printing anything. There is no flag that skips the boot: stop the
  running Lemon, or run the command from a host that is not serving with the
  same `HONCHO_*` variables exported.

  ## Options

    * `--session` / `-s` — session key for `context`. Defaults to the most
      recently refreshed session this node knows about, and falls back to the
      current directory when the node has served no turns yet.
    * `--query` / `-q` — the user message context is assembled against, which is
      what steers the dialectic supplement. Only `--live` sends it anywhere.
    * `--timeout` / `-t` — milliseconds to allow the probe in `status` and
      `ping`. See the bound below.
    * `--live` — let `context` assemble the block through the production turn
      path instead of reading what is already cached. See the warning below.
    * `--help` / `-h` — print this text.

  ## How long a probe can take

  `ping` and `status` make **one** request and never retry it, so the worst case
  is the number you can see: `--timeout` when you pass one, otherwise
  `HONCHO_TIMEOUT_MS` (30 s by default) for `ping` and 5 s for `status` — the
  shorter cap being why `status` is a glance and `ping` is the real bound.

  Ordinary requests, on the turn path, still retry a transient failure; only the
  diagnostic path is capped. That distinction is the whole point: an operator
  watching a terminal needs an answer within the stated time even if a longer
  wait would have succeeded, which is exactly the wrong trade for a turn.

  ## `context` is read-only unless you ask for `--live`

  By default `context` reports what this node already holds for a session —
  whether it is tracked at all, which Honcho session it maps to, how many turns
  it has served, when its block was last refreshed — and touches neither the
  network nor the session's state. It stops short of printing the block itself,
  because `LemonHoncho.SessionManager` hands that back only through the path a
  turn takes.

  `--live` assembles the block by calling the same code path a real turn calls.
  Against a live node that means: the session's turn counter advances, a
  background refresh may start, the dialectic cadence window moves — and the
  dialectic is a billed call. A `--session` key this node has never served is
  created as a new tracked session. None of that is acceptable as the default
  behaviour of a command whose job is to explain, so it is opt-in.

  ## Secrets

  Nothing here prints `HONCHO_API_KEY`. `status` reports the key as present or
  absent and never echoes it, not even a prefix, and every error this task
  renders is scrubbed of the configured key first — a remote service that quotes
  a credential back inside an error body should not turn a diagnostic command
  into a leak.

  ## Not configured is not an error

  `status` exits 0 when Honcho has neither an API key nor a base URL, and says
  which variables to set. A Lemon install without Honcho is a supported
  deployment, so a status command that failed there would be reporting the wrong
  thing. `ping` is the opposite: it exists to be scripted, so an unconfigured
  install fails it like any other unreachable endpoint.
  """

  alias LemonHoncho.Client
  alias LemonHoncho.Config
  alias LemonHoncho.SessionManager

  @subcommands ~w(status sessions ping context)

  # Wide enough for "Dialectic cadence", the longest label printed below.
  @label_width 18

  # `status` is a glance, not a health check, so its probe is capped well under
  # the configured request timeout: an operator waiting on a wedged endpoint
  # should get "unreachable" in seconds and reach for `ping` for the real bound.
  #
  # This is a bound on the *whole* probe, not on one attempt of it. It used to
  # be per attempt, which is not the same number: the client retried twice with
  # exponential backoff, so "unreachable in seconds" was really eighteen of
  # them, and `ping`'s 30-second default was ninety-three. Both probes now ask
  # the client for a single attempt inside an explicit ceiling.
  @probe_timeout_ms 5_000

  # An error rendered from a remote body can be long. It is scrubbed *before*
  # being cut, so a truncation can never expose the tail of a redacted key.
  @reason_max_chars 500

  # Refuse to scrub a suspiciously short key: replacing every "ab" in an error
  # would corrupt the diagnostic without protecting anything real.
  @min_scrubbable_key 6

  @impl true
  def run(args) do
    {opts, rest, invalid} =
      OptionParser.parse(args,
        switches: [
          session: :string,
          query: :string,
          timeout: :integer,
          live: :boolean,
          help: :boolean
        ],
        aliases: [s: :session, q: :query, t: :timeout, h: :help]
      )

    cond do
      opts[:help] -> info(@moduledoc)
      invalid != [] -> Mix.raise("Invalid options. Run `mix lemon.honcho --help`.")
      true -> dispatch(rest, opts)
    end
  end

  ## Public helpers
  #
  # The formatting below is separated from the printing so it can be tested by
  # value rather than by capturing a terminal. That matters most for `status`,
  # whose one hard guarantee — the API key never appears — is a property of
  # these lines and is asserted against them directly.

  @doc """
  The `status` report for a config, as lines, without touching the network.

  The API key is reported as `present` or `absent`; its value never appears in
  the result, so these lines are safe to log or paste into an issue.

  ## Examples

      iex> lines = Mix.Tasks.Lemon.Honcho.status_lines(%LemonHoncho.Config{api_key: "sk-secret"})
      iex> Enum.any?(lines, &(&1 =~ "API key" and &1 =~ "present"))
      true
  """
  @spec status_lines(Config.t()) :: [String.t()]
  def status_lines(%Config{} = config) do
    [
      field("Configured", yes_no(Config.configured?(config))),
      field("Enabled", yes_no(config.enabled?)),
      field("API key", key_presence(config)),
      field("Base URL", config.base_url || "(none — #{config.environment} deployment)"),
      field("Environment", config.environment),
      field("Workspace", config.workspace),
      field("User peer", config.user_peer),
      field("AI peer", config.ai_peer),
      field("Recall mode", config.recall_mode),
      field("Session strategy", config.session_strategy),
      field("Observation mode", config.observation_mode),
      field("Context cadence", cadence(config.context_cadence)),
      field("Dialectic cadence", cadence(config.dialectic_cadence)),
      field("Context budget", context_budget(config.context_tokens)),
      field("Dialectic budget", "#{config.dialectic_max_chars} characters"),
      field("Request timeout", "#{config.timeout_ms} ms"),
      field("Save messages", yes_no(config.save_messages?)),
      field("Subagent context", yes_no(config.inject_in_subagents?))
    ]
  end

  @doc """
  The `sessions` table for a list of `LemonHoncho.SessionManager` session infos.

  An empty list renders as a one-line explanation rather than as a bare header,
  because a session table that is empty because nothing has run yet looks
  identical to one that is empty because something is broken — and, on a machine
  where Lemon is running, identical to the far more likely case: this task's node
  is not that one, and never holds its sessions. See the moduledoc.
  """
  @spec session_lines([map()]) :: [String.t()]
  def session_lines([]) do
    ["  No sessions tracked yet — this command's own node has served none, and sees no other's."]
  end

  def session_lines(sessions) when is_list(sessions) do
    key_width = column_width(sessions, :session_key, "SESSION KEY")
    id_width = column_width(sessions, :honcho_session_id, "HONCHO SESSION ID")

    header =
      "  " <>
        String.pad_trailing("SESSION KEY", key_width) <>
        "  " <> String.pad_trailing("HONCHO SESSION ID", id_width) <> "  TURNS  LAST CONTEXT"

    [header | Enum.map(sessions, &session_row(&1, key_width, id_width))]
  end

  @doc """
  Renders a failure reason for the terminal with the configured API key removed.

  Every error path in this task goes through here. Honcho's error bodies are
  passed straight through by `LemonHoncho.Client`, and an upstream that echoes
  an `Authorization` header into a 4xx body would otherwise print the key.

  ## Examples

      iex> config = %LemonHoncho.Config{api_key: "sk-honcho-secret"}
      iex> Mix.Tasks.Lemon.Honcho.redact({:unauthorized, "bad key sk-honcho-secret"}, config)
      "{:unauthorized, \\"bad key [redacted]\\"}"
  """
  @spec redact(term(), Config.t()) :: String.t()
  def redact(reason, %Config{} = config) do
    reason
    |> inspect(limit: :infinity)
    |> scrub(config.api_key)
    |> String.slice(0, @reason_max_chars)
  end

  ## Dispatch

  defp dispatch([], _opts), do: info(@moduledoc)
  defp dispatch(["status"], opts), do: run_status(opts)
  defp dispatch(["sessions"], _opts), do: run_sessions()
  defp dispatch(["ping"], opts), do: run_ping(opts)
  defp dispatch(["context"], opts), do: run_context(opts)

  # A known subcommand with leftovers is almost always a mistyped switch, and
  # saying "unknown subcommand `status`" about it would send the operator
  # looking in the wrong place.
  defp dispatch([subcommand | rest], _opts) when subcommand in @subcommands do
    Mix.raise(
      "`mix lemon.honcho #{subcommand}` takes no extra arguments, got: #{Enum.join(rest, " ")}."
    )
  end

  defp dispatch([subcommand | _rest], _opts) do
    Mix.raise("Unknown subcommand #{inspect(subcommand)}. Run `mix lemon.honcho --help`.")
  end

  ## Subcommands

  defp run_status(opts) do
    Mix.Task.run("app.start")

    config = LemonHoncho.config()

    header("Honcho Memory")
    Enum.each(status_lines(config), &info/1)
    info("")

    if Config.configured?(config) do
      report_reachability(config, timeout_for(opts, min(config.timeout_ms, @probe_timeout_ms)))
    else
      explain_unconfigured(config)
    end
  end

  defp run_sessions do
    Mix.Task.run("app.start")

    header("Honcho Sessions")

    if manager_running?() do
      Enum.each(session_lines(SessionManager.sessions()), &info/1)
    else
      info("  Session manager is not running; this node has no mappings to show.")
    end
  end

  defp run_ping(opts) do
    Mix.Task.run("app.start")

    config = LemonHoncho.config()

    case probe(config, timeout_for(opts, config.timeout_ms)) do
      {{:ok, _body}, elapsed_ms} ->
        info([:green, "ok", :reset, " — Honcho answered in #{elapsed_ms} ms"])

      {{:error, reason}, elapsed_ms} ->
        Mix.raise("Honcho unreachable after #{elapsed_ms} ms: #{redact(reason, config)}")

      {other, elapsed_ms} ->
        Mix.raise("Honcho answered unusably after #{elapsed_ms} ms: #{redact(other, config)}")
    end
  end

  defp run_context(opts) do
    Mix.Task.run("app.start")

    config = LemonHoncho.config()
    session_key = opts[:session] || latest_session_key()
    live? = opts[:live] == true

    header("Honcho Context")
    info(field("Session key", session_key || "(none — using this directory)"))
    info(field("Recall mode", config.recall_mode))
    info(field("Query", opts[:query] || "(none)"))
    info(field("Mode", mode_label(live?)))
    info("")

    cond do
      not manager_running?() ->
        info("  Session manager is not running; nothing would be injected.")

      live? ->
        assemble_block(session_key, opts, config)

      true ->
        Enum.each(cached_lines(session_key), &info/1)
    end
  end

  defp mode_label(true), do: "live (assembles the block, advances this session)"
  defp mode_label(false), do: "read-only (pass --live to assemble the block for real)"

  ## Status detail

  # A live probe, capped short. Reported as a separate section from the config
  # so an operator can tell "misconfigured" from "configured and the service is
  # down" — the two have entirely different fixes.
  defp report_reachability(%Config{} = config, timeout_ms) do
    info("Reachability")

    case probe(config, timeout_ms) do
      {{:ok, _body}, elapsed_ms} ->
        info(field("Honcho API", "reachable in #{elapsed_ms} ms"))

      {{:error, reason}, elapsed_ms} ->
        info(
          field("Honcho API", "unreachable after #{elapsed_ms} ms — #{redact(reason, config)}")
        )

      {other, elapsed_ms} ->
        info(field("Honcho API", "unusable after #{elapsed_ms} ms — #{redact(other, config)}"))
    end
  end

  defp explain_unconfigured(%Config{} = config) do
    info("Not configured")

    if config.enabled? do
      info("  Honcho has nowhere to talk to. Set one of:")
      info("")
      info("    HONCHO_API_KEY   key for the hosted deployment (api.honcho.dev)")
      info("    HONCHO_BASE_URL  base URL of a self-hosted deployment")
    else
      info("  Switched off by LEMON_HONCHO_ENABLED. Set it to true to re-enable,")
      info("  then set HONCHO_API_KEY or HONCHO_BASE_URL.")
    end

    info("")
    info("  Optional: HONCHO_WORKSPACE, HONCHO_PEER, HONCHO_AI_PEER,")
    info("  HONCHO_ENVIRONMENT, LEMON_HONCHO_RECALL_MODE,")
    info("  LEMON_HONCHO_SESSION_STRATEGY. See `LemonHoncho.Env` for all of them.")
    info("")
    info("  Running without Honcho is supported, so this is not a failure.")
  end

  ## Context detail

  # Everything that can be said about a session without touching it.
  # `LemonHoncho.SessionManager` exposes no read-only accessor for the cached
  # block — `context_for/1` *is* the turn path — but `sessions/0` does read the
  # manager's state without mutating it, so the default answer is the session's
  # tracked state plus a plain statement of what `--live` would add.
  defp cached_lines(session_key) do
    case tracked_session(session_key) do
      nil -> untracked_lines(session_key)
      session -> tracked_lines(session)
    end
  end

  defp tracked_lines(session) do
    ["  This node is tracking that session:", "" | session_lines([session])] ++
      [
        "",
        "  The cached block itself is not shown: the session manager returns it",
        "  only through the path a turn takes, which `--live` is for."
      ]
  end

  defp untracked_lines(nil) do
    [
      "  This node has served no turns, so there is nothing cached to show.",
      "  Nothing was created here — `--live` would create a session entry."
    ]
  end

  defp untracked_lines(session_key) do
    [
      "  This node has served no turns for #{inspect(session_key)}, so there is",
      "  nothing cached to show. Nothing was created here — `--live` would create",
      "  a session entry under that key."
    ]
  end

  defp tracked_session(nil), do: nil

  defp tracked_session(session_key) do
    Enum.find(known_sessions(), &(&1.session_key == session_key))
  end

  # The mutating path, entered only on `--live`. The warning is printed before
  # the call and not after it, so a run that then blocks on a first-turn refresh
  # has already said what it is doing and to which session.
  defp assemble_block(session_key, opts, %Config{} = config) do
    info("  Assembling through the turn path: this counts a turn against")
    info("  #{session_key || "this directory"} and may bill a dialectic call.")
    info("")

    session_key
    |> context_request(opts[:query])
    |> SessionManager.context_for()
    |> render_block(config)
  end

  defp render_block("", %Config{} = config) do
    info("  (empty — nothing would be injected)")
    info("")
    Enum.each(empty_block_reasons(config), &info("  - " <> &1))
  end

  defp render_block(block, _config) do
    info("--- begin injected block ---")
    info(block)
    info("--- end injected block ---")
  end

  # Ordered most-likely-cause first, because an empty block is nearly always a
  # configuration answer and only rarely a "not yet" answer.
  defp empty_block_reasons(%Config{} = config) do
    [
      "Honcho may not have answered for this session yet; the first refresh runs off the turn path.",
      "A session with no history yet has nothing to recall."
    ]
    |> prepend_if(
      config.recall_mode == :tools,
      "Recall mode is :tools — memory reaches the model as tools, not as injected context."
    )
    |> prepend_if(not Config.configured?(config), "Honcho is not configured.")
  end

  defp prepend_if(reasons, true, reason), do: [reason | reasons]
  defp prepend_if(reasons, _false, _reason), do: reasons

  defp context_request(nil, query), do: base_request(query)

  defp context_request(session_key, query) do
    Map.put(base_request(query), :session_key, session_key)
  end

  defp base_request(query) do
    %{cwd: cwd(), session_scope: :main, query: query || ""}
  end

  defp cwd do
    case File.cwd() do
      {:ok, dir} -> dir
      {:error, _reason} -> "."
    end
  end

  # "Most recent" is the session Honcho answered for last, which is the one an
  # operator is nearly always asking about. A session that has never been
  # refreshed sorts last rather than being skipped.
  defp latest_session_key do
    case known_sessions() do
      [] ->
        nil

      sessions ->
        sessions |> Enum.max_by(&(&1.last_context_at_ms || 0)) |> Map.get(:session_key)
    end
  end

  defp known_sessions do
    if manager_running?(), do: SessionManager.sessions(), else: []
  end

  ## Probing

  # Returns `{result, elapsed_ms}`. The client module is read from the
  # application env exactly as `LemonHoncho.SessionManager` reads it, so a test
  # can substitute a stub without this task growing a transport parameter.
  #
  # `timeout_ms` bounds the whole probe rather than one attempt of it: the call
  # is made with retries switched off and an explicit ceiling, which is what
  # lets the moduledoc state a worst case an operator can rely on. It also
  # overwrites `config.timeout_ms`, so an explicit `--timeout` longer than
  # `HONCHO_TIMEOUT_MS` really does wait longer — a deliberate choice, since the
  # operator typed the larger number knowing what it meant.
  defp probe(%Config{} = config, timeout_ms) do
    probe_config = %{config | timeout_ms: timeout_ms}
    started = System.monotonic_time(:millisecond)
    result = safe_ensure_workspace(probe_config, timeout_ms)

    {result, System.monotonic_time(:millisecond) - started}
  end

  defp safe_ensure_workspace(%Config{} = config, timeout_ms) do
    client().ensure_workspace(config, max_retries: 0, total_timeout: timeout_ms)
  rescue
    error -> {:error, error}
  catch
    :exit, reason -> {:error, {:exit, reason}}
  end

  # `--timeout` is parsed as an integer, so a non-numeric value is already an
  # "Invalid options" failure by the time we get here; what is left to reject is
  # a number that cannot bound anything.
  defp timeout_for(opts, default) do
    case Keyword.get(opts, :timeout) do
      nil -> default
      ms when is_integer(ms) and ms > 0 -> ms
      other -> Mix.raise("--timeout must be a positive number of milliseconds, got: #{other}")
    end
  end

  defp client, do: Application.get_env(:lemon_honcho, :client, Client)

  defp manager_running?, do: is_pid(Process.whereis(SessionManager))

  ## Formatting

  # One printing funnel, so a line can be captured in a test and so the shell is
  # resolved at call time rather than captured — `Mix.shell/0` is swappable and
  # a task that cached it would ignore the swap.
  defp info(message), do: Mix.shell().info(message)

  defp header(title) do
    info(title)
    info(String.duplicate("=", String.length(title)))
  end

  defp field(label, value) do
    "  " <> String.pad_trailing(to_string(label), @label_width) <> ": " <> to_string(value)
  end

  defp yes_no(true), do: "yes"
  defp yes_no(_other), do: "no"

  defp key_presence(%Config{api_key: key}) when is_binary(key) and key != "", do: "present"
  defp key_presence(%Config{}), do: "absent"

  defp cadence(1), do: "every turn"
  defp cadence(n), do: "every #{n} turns"

  defp context_budget(nil), do: "unlimited"
  defp context_budget(tokens), do: "#{tokens} tokens (~#{tokens * 4} characters)"

  # Columns are sized to their content but never narrower than their heading, so
  # a node with one short session key still prints a table that lines up.
  defp column_width(sessions, key, heading) do
    widths = Enum.map(sessions, &String.length(to_string(Map.get(&1, key) || "(pending)")))

    Enum.max([String.length(heading) | widths])
  end

  defp session_row(session, key_width, id_width) do
    "  " <>
      String.pad_trailing(to_string(session.session_key), key_width) <>
      "  " <>
      String.pad_trailing(to_string(session.honcho_session_id || "(pending)"), id_width) <>
      "  " <>
      String.pad_leading(to_string(session.turns), 5) <>
      "  " <> format_ms(session.last_context_at_ms)
  end

  defp format_ms(nil), do: "(never)"

  defp format_ms(ms) when is_integer(ms) do
    ms
    |> DateTime.from_unix!(:millisecond)
    |> Calendar.strftime("%Y-%m-%d %H:%M UTC")
  rescue
    _error -> "(invalid)"
  end

  defp format_ms(_other), do: "(never)"

  defp scrub(text, key) when is_binary(key) and byte_size(key) >= @min_scrubbable_key do
    String.replace(text, key, "[redacted]")
  end

  defp scrub(text, _key), do: text
end
