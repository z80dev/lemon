defmodule LemonWeb.DiagnosticsLive do
  @moduledoc """
  `/diagnostics`: runtime health, versions, counts, setup readiness, the
  `lemon doctor` checks and a live log tail.

  Sources: `health`, `status`, `doctor.run` (async; the CLI doctor suite run
  in-process, redacted, without writing a support bundle), `logs.tail` and
  `LemonCore.Setup.Readiness` (booleans/identifiers only — the config path is
  never assigned). Log and doctor text additionally passes through
  `LemonWeb.ManagementText`, which hides path-like tokens and secrets.

  The page refreshes health, status and (unless paused) logs every 5 seconds
  while connected. "Copy summary" copies a plain-text, redacted digest for bug
  reports.
  """

  use LemonWeb, :live_view

  alias LemonCore.Setup.Readiness
  alias LemonWeb.{ManagementText, Rpc}

  @tick_ms 5_000
  @log_limit 200
  @levels ~w(all info warning error)
  @identifier ~r/^[A-Za-z0-9][A-Za-z0-9._:@\/+-]{0,127}$/

  @impl true
  def mount(_params, _session, socket) do
    socket =
      assign(socket,
        nav: :diagnostics,
        page_title: "Diagnostics · Lemon",
        page_heading: "Diagnostics",
        health: nil,
        status: nil,
        readiness: nil,
        doctor: nil,
        doctor_state: :idle,
        logs: [],
        logs_state: :loading,
        log_level: "all",
        log_follow: true
      )
      |> load_runtime()
      |> load_readiness()
      |> load_logs()

    socket =
      if connected?(socket) do
        Process.send_after(self(), :tick, @tick_ms)
        run_doctor(socket)
      else
        socket
      end

    {:ok, socket}
  end

  @impl true
  def handle_info(:tick, socket) do
    Process.send_after(self(), :tick, @tick_ms)
    socket = load_runtime(socket)
    {:noreply, if(socket.assigns.log_follow, do: load_logs(socket), else: socket)}
  end

  @impl true
  def handle_event("refresh", _params, socket) do
    {:noreply, socket |> load_runtime() |> load_readiness() |> load_logs()}
  end

  def handle_event("run-doctor", _params, socket), do: {:noreply, run_doctor(socket)}

  def handle_event("log-level", %{"level" => level}, socket) when level in @levels do
    {:noreply, socket |> assign(:log_level, level) |> load_logs()}
  end

  def handle_event("toggle-follow", _params, socket) do
    follow = not socket.assigns.log_follow
    socket = assign(socket, :log_follow, follow)
    {:noreply, if(follow, do: load_logs(socket), else: socket)}
  end

  def handle_event("refresh-logs", _params, socket), do: {:noreply, load_logs(socket)}

  @impl true
  def handle_async(:doctor, {:ok, {:ok, %{} = report}}, socket),
    do: {:noreply, assign(socket, doctor: project_doctor(report), doctor_state: :ok)}

  def handle_async(:doctor, _result, socket),
    do: {:noreply, assign(socket, doctor_state: :unavailable)}

  # ── Data ────────────────────────────────────────────────────────────────

  defp load_runtime(socket) do
    health =
      case Rpc.call("health", %{}) do
        {:ok, %{} = health} ->
          %{
            ok: health["ok"] == true,
            uptime_ms: integer(health["uptime_ms"]),
            memory_mb: number(health["memory_mb"]),
            schedulers: integer(health["schedulers"])
          }

        _ ->
          :unavailable
      end

    status =
      case Rpc.call("status", %{}) do
        {:ok, %{} = status} -> project_status(status)
        _ -> :unavailable
      end

    assign(socket, health: health, status: status)
  end

  defp project_status(status) do
    server = map(status["server"])
    beam = map(server["beam"])
    connections = map(status["connections"])
    runs = map(status["runs"])
    channels = map(status["channels"])
    skills = map(status["skills"])

    %{
      version: identifier(server["version"]),
      otp: identifier(server["otp_release"]),
      elixir: System.version(),
      processes: {integer(beam["processCount"]), integer(beam["processLimit"])},
      ports: {integer(beam["portCount"]), integer(beam["portLimit"])},
      atoms: {integer(beam["atomCount"]), integer(beam["atomLimit"])},
      run_queue: integer(beam["runQueue"]),
      clients: integer(connections["active"]),
      operators: integer(connections["operators"]),
      nodes: integer(connections["nodes"]),
      active_runs: run_count(runs["active"]),
      queued_runs: run_count(runs["queued"]),
      completed_today: run_count(runs["completed_today"]),
      failed_today: run_count(runs["failed_today"]),
      channels_configured: identifiers(channels["configured"]),
      channels_connected: identifiers(channels["connected"]),
      skills_installed: integer(skills["installed"]),
      skills_enabled: integer(skills["enabled"])
    }
  end

  defp load_readiness(socket) do
    state =
      case Application.get_env(:lemon_web, :setup_readiness_fun) do
        fun when is_function(fun, 0) -> fun.()
        _ -> Readiness.status()
      end

    provider = map(state[:provider])

    assign(socket, :readiness, %{
      config: map(state[:config])[:complete] == true,
      secrets: map(state[:secrets])[:complete] == true,
      provider: provider[:complete] == true,
      provider_name: identifier(provider[:provider]),
      model: identifier(provider[:model]),
      reason: provider[:reason],
      ready: Readiness.ready?(state)
    })
  rescue
    _ -> assign(socket, :readiness, :unavailable)
  catch
    :exit, _ -> assign(socket, :readiness, :unavailable)
  end

  defp run_doctor(socket) do
    socket
    |> assign(:doctor_state, :running)
    |> start_async(:doctor, fn -> Rpc.call("doctor.run", %{}) end)
  end

  defp project_doctor(report) do
    counts = map(report["counts"])

    %{
      overall: if(report["overall"] in ~w(pass warn fail), do: report["overall"], else: "warn"),
      counts: Map.new(~w(pass warn fail skip), &{&1, integer(counts[&1])}),
      truncated: report["truncated"] == true,
      generated_at_ms: if(is_integer(report["generatedAtMs"]), do: report["generatedAtMs"]),
      checks:
        report["checks"]
        |> List.wrap()
        |> Enum.take(64)
        |> Enum.flat_map(fn
          %{"name" => name, "status" => status} = check when status in ~w(pass warn fail skip) ->
            [
              %{
                name: ManagementText.text(to_string(name)),
                status: status,
                message: safe_text(check["message"]),
                remediation: safe_text(check["remediation"])
              }
            ]

          _ ->
            []
        end)
        |> Enum.sort_by(&status_rank(&1.status))
    }
  end

  defp load_logs(socket) do
    params =
      case socket.assigns.log_level do
        "all" -> %{"limit" => @log_limit}
        level -> %{"limit" => @log_limit, "level" => level}
      end

    case Rpc.call("logs.tail", params) do
      {:ok, %{"logs" => logs}} when is_list(logs) ->
        assign(socket,
          logs: logs |> Enum.take(-@log_limit) |> Enum.flat_map(&project_log/1),
          logs_state: :ok
        )

      _ ->
        assign(socket, logs: [], logs_state: :unavailable)
    end
  end

  defp project_log(%{} = entry) do
    level = entry["level"] || entry[:level]

    [
      %{
        level:
          if(is_binary(level) and Regex.match?(~r/^[a-z]{1,12}$/, level), do: level, else: "info"),
        at_ms: if(is_integer(entry["timestampMs"]), do: entry["timestampMs"]),
        module: identifier(entry["module"]),
        message: safe_text(entry["message"]) || ""
      }
    ]
  end

  defp project_log(_entry), do: []

  defp safe_text(text) when is_binary(text),
    do: text |> String.slice(0, 2_000) |> ManagementText.text()

  defp safe_text(_text), do: nil

  defp map(value) when is_map(value), do: value
  defp map(_value), do: %{}

  defp identifier(value) when is_atom(value) and not is_nil(value),
    do: identifier(Atom.to_string(value))

  defp identifier(value) when is_binary(value) do
    if Regex.match?(@identifier, value), do: value
  end

  defp identifier(_value), do: nil

  defp identifiers(values),
    do:
      values |> List.wrap() |> Enum.map(&identifier/1) |> Enum.reject(&is_nil/1) |> Enum.take(24)

  defp integer(value) when is_integer(value) and value >= 0, do: value
  defp integer(_value), do: 0

  defp run_count(value) when is_integer(value) and value >= 0, do: value
  defp run_count(_value), do: "unknown"

  defp number(value) when is_number(value) and value >= 0, do: value * 1.0
  defp number(_value), do: 0.0

  defp status_rank("fail"), do: 0
  defp status_rank("warn"), do: 1
  defp status_rank("pass"), do: 2
  defp status_rank(_status), do: 3

  # ── Render ──────────────────────────────────────────────────────────────

  @impl true
  def render(assigns) do
    assigns = assign(assigns, :summary, summary_text(assigns))

    ~H"""
    <.page wide>
      <.page_header title="Diagnostics" icon="stethoscope" subtitle="Runtime health, setup readiness, doctor checks and recent logs.">
        <:meta>
          <.badge :if={is_map(@health) and @health.ok} tone="success" icon="check-circle">Runtime healthy</.badge>
          <.badge :if={@health == :unavailable} tone="danger" icon="alert-circle">Runtime unreachable</.badge>
          <.badge :if={is_map(@status) and @status.version} tone="neutral">v{@status.version}</.badge>
        </:meta>
        <:actions>
          <button
            type="button"
            id="diagnostics-copy"
            class="btn btn-secondary"
            phx-hook="CopyButton"
            data-copy-text={@summary}
            aria-label="Copy redacted diagnostics summary"
          >
            <.icon name="copy" /> Copy summary
          </button>
          <.button icon="refresh" phx-click="refresh">Refresh</.button>
        </:actions>
      </.page_header>

      <section aria-label="Runtime" class="mb-5 grid grid-cols-2 gap-3 md:grid-cols-3 xl:grid-cols-6">
        <.stat label="Uptime" icon="clock" value={health_value(@health, &duration(&1.uptime_ms))} />
        <.stat label="Memory" icon="gauge" value={health_value(@health, &"#{round(&1.memory_mb)} MB")} />
        <.stat label="Active runs" icon="activity" value={status_value(@status, & &1.active_runs)} hint={status_hint(@status, &"#{&1.queued_runs} queued · #{&1.completed_today} today · #{&1.failed_today} failed today")} />
        <.stat label="Clients" icon="users" value={status_value(@status, & &1.clients)} hint={status_hint(@status, &"#{&1.operators} operators")} />
        <.stat label="Nodes" icon="server" value={status_value(@status, & &1.nodes)} hint="Paired execution nodes" />
        <.stat label="Skills" icon="sparkles" value={status_value(@status, & &1.skills_enabled)} hint={status_hint(@status, &"#{&1.skills_installed} installed")} />
      </section>

      <.callout :if={@status == :unavailable} tone="danger" title="Runtime status unavailable" class="mb-4" id="status-unavailable">
        The control plane did not answer the status request. Health and counts are not shown until it does.
      </.callout>

      <div class="grid gap-4 xl:grid-cols-3">
        <.card id="readiness-card">
          <:header>Setup readiness</:header>
          <:actions>
            <.badge :if={is_map(@readiness)} tone={if @readiness.ready, do: "success", else: "warning"}>
              {if @readiness.ready, do: "Ready", else: "Action needed"}
            </.badge>
          </:actions>
          <p :if={@readiness == :unavailable} class="text-[13px] text-muted">Readiness could not be determined. Run <code class="font-mono">lemon doctor</code> in a terminal for details.</p>
          <ul :if={is_map(@readiness)} class="space-y-2.5 text-[13px]">
            <.readiness_step ok={@readiness.config} label="Config file" hint="Global config file (config.toml) is present" fix="lemon setup" />
            <.readiness_step ok={@readiness.secrets} label="Secrets" hint="Secret store key is set up" fix="lemon setup" />
            <.readiness_step
              ok={@readiness.provider}
              label="Default provider"
              hint={provider_hint(@readiness)}
              fix="lemon setup provider"
            />
          </ul>
        </.card>

        <.card id="versions-card">
          <:header>Versions &amp; capacity</:header>
          <p :if={not is_map(@status)} class="text-[13px] text-muted">Unavailable.</p>
          <div :if={is_map(@status)} class="space-y-3">
            <.key_value>
              <:item label="Lemon">{@status.version || "—"}</:item>
              <:item label="Erlang/OTP">{@status.otp || "—"}</:item>
              <:item label="Elixir">{@status.elixir}</:item>
              <:item label="Schedulers">{health_value(@health, & &1.schedulers)}</:item>
              <:item label="Run queue">{@status.run_queue}</:item>
            </.key_value>
            <.capacity label="Processes" pair={@status.processes} />
            <.capacity label="Ports" pair={@status.ports} />
            <.capacity label="Atoms" pair={@status.atoms} />
          </div>
        </.card>

        <.card id="channels-card">
          <:header>Channels</:header>
          <p :if={not is_map(@status)} class="text-[13px] text-muted">Unavailable.</p>
          <div :if={is_map(@status)}>
            <p :if={@status.channels_configured == []} class="text-[13px] text-muted">
              No chat channels configured. The web UI, TUI and CLI work without them.
            </p>
            <ul :if={@status.channels_configured != []} class="space-y-1.5 text-[13px]">
              <li :for={channel <- @status.channels_configured} class="flex items-center gap-2">
                <.status_dot tone={if channel in @status.channels_connected, do: "success", else: "warning"} />
                <span class="flex-1">{channel}</span>
                <span class="text-xs text-muted">{if channel in @status.channels_connected, do: "connected", else: "not connected"}</span>
              </li>
            </ul>
          </div>
        </.card>

        <.card id="doctor-card" class="xl:col-span-3">
          <:header>
            <span class="flex items-center gap-2">
              Doctor
              <.badge :if={@doctor_state == :ok} tone={overall_tone(@doctor.overall)}>{overall_label(@doctor.overall)}</.badge>
            </span>
          </:header>
          <:actions>
            <span :if={@doctor_state == :ok and @doctor.generated_at_ms} class="hidden text-xs text-subtle sm:inline">
              Ran {relative_time(@doctor.generated_at_ms)}
            </span>
            <.button size="sm" icon="play" phx-click="run-doctor" loading={@doctor_state == :running} id="run-doctor">
              {if @doctor_state == :running, do: "Running…", else: "Run checks"}
            </.button>
          </:actions>
          <p class="mb-3 text-xs text-muted">
            The same checks as <code class="font-mono text-fg">lemon doctor</code>, run inside the daemon (read-only).
            For a support bundle run <code class="font-mono text-fg">lemon doctor --bundle</code> in a terminal.
          </p>
          <.callout :if={@doctor_state == :unavailable} tone="warning" title="Doctor checks unavailable" id="doctor-unavailable">
            The runtime could not run the checks. Run <code class="font-mono">lemon doctor</code> in a terminal instead.
          </.callout>
          <div :if={@doctor_state in [:idle, :running] and is_nil(@doctor)} class="flex items-center gap-2 py-3 text-[13px] text-muted">
            <.spinner /> Running checks…
          </div>
          <div :if={@doctor} class="space-y-3">
            <div class="flex flex-wrap gap-2 text-xs">
              <.badge tone="success">{@doctor.counts["pass"]} passed</.badge>
              <.badge tone="warning">{@doctor.counts["warn"]} warnings</.badge>
              <.badge tone="danger">{@doctor.counts["fail"]} failed</.badge>
              <.badge tone="neutral">{@doctor.counts["skip"]} skipped</.badge>
            </div>
            <ul id="doctor-checks" class="divide-y divide-line rounded-lg border border-line">
              <li :for={check <- @doctor.checks} class="flex gap-3 px-3 py-2.5">
                <.icon name={check_icon(check.status)} class={["mt-0.5 h-4 w-4", check_color(check.status)]} />
                <div class="min-w-0 flex-1">
                  <div class="flex flex-wrap items-baseline gap-x-2">
                    <span class="font-mono text-xs font-medium text-fg">{check.name}</span>
                    <span class="sr-only">{check.status}</span>
                  </div>
                  <p :if={check.message} class="mt-0.5 whitespace-pre-line break-words text-[13px] text-muted">{check.message}</p>
                  <p :if={check.remediation} class="mt-1 whitespace-pre-line break-words text-xs text-info">→ {check.remediation}</p>
                </div>
              </li>
            </ul>
            <p :if={@doctor.truncated} class="text-xs text-subtle">Only the first 64 checks are shown.</p>
          </div>
        </.card>

        <.card id="logs-card" class="xl:col-span-3" body_class="">
          <:header>Logs</:header>
          <:actions>
            <div class="segmented" role="group" aria-label="Minimum log level">
              <button
                :for={level <- ~w(all info warning error)}
                type="button"
                phx-click="log-level"
                phx-value-level={level}
                aria-pressed={to_string(@log_level == level)}
              >
                {level_label(level)}
              </button>
            </div>
            <.button
              size="sm"
              variant="ghost"
              icon={if @log_follow, do: "pause", else: "play"}
              phx-click="toggle-follow"
              id="logs-follow"
              aria-pressed={to_string(@log_follow)}
            >
              {if @log_follow, do: "Live", else: "Paused"}
            </.button>
          </:actions>
          <.callout :if={@logs_state == :unavailable} tone="warning" class="m-3" id="logs-unavailable">
            Logs are unavailable right now. Run <code class="font-mono">lemon doctor</code> in a terminal for details.
          </.callout>
          <div :if={@logs_state == :ok and @logs == []} class="px-4 py-8 text-center text-[13px] text-muted">
            No log entries at this level yet.
          </div>
          <ol
            :if={@logs != []}
            id="log-lines"
            class="max-h-[28rem] overflow-y-auto py-1 font-mono text-xs leading-relaxed scroll-thin"
            aria-live="off"
          >
            <li :for={log <- Enum.reverse(@logs)} class="flex gap-3 px-3 py-0.5 hover:bg-surface-2/60">
              <time class="shrink-0 tabular-nums text-subtle">{log_time(log.at_ms)}</time>
              <span class={["w-14 shrink-0 font-semibold uppercase", level_color(log.level)]}>{log.level}</span>
              <span class="min-w-0 flex-1 whitespace-pre-wrap break-words text-fg">
                <span :if={log.module} class="text-subtle">{log.module} </span>{log.message}
              </span>
            </li>
          </ol>
          <:footer>
            <p class="text-xs text-subtle">
              Newest first · last {length(@logs)} entries (in-memory tail of up to 1000) · secrets and paths are hidden.
            </p>
          </:footer>
        </.card>
      </div>
    </.page>
    """
  end

  attr(:ok, :boolean, required: true)
  attr(:label, :string, required: true)
  attr(:hint, :string, required: true)
  attr(:fix, :string, required: true)

  defp readiness_step(assigns) do
    ~H"""
    <li class="flex gap-2.5">
      <.icon
        name={if @ok, do: "check-circle", else: "alert-circle"}
        class={["mt-0.5 h-4 w-4", if(@ok, do: "text-success", else: "text-warning")]}
      />
      <div class="min-w-0">
        <p class="font-medium text-fg">{@label}</p>
        <p class="text-xs text-muted">{@hint}</p>
        <p :if={not @ok} class="mt-0.5 text-xs text-muted">
          Fix: <code class="font-mono text-fg">{@fix}</code>
        </p>
      </div>
    </li>
    """
  end

  attr(:label, :string, required: true)
  attr(:pair, :any, required: true)

  defp capacity(assigns) do
    ~H"""
    <div class="space-y-1">
      <div class="flex justify-between text-xs">
        <span class="text-muted">{@label}</span>
        <span class="tabular-nums text-fg">{compact_number(elem(@pair, 0))} / {compact_number(elem(@pair, 1))}</span>
      </div>
      <.meter value={elem(@pair, 0)} max={elem(@pair, 1)} auto_tone label={"#{@label} used"} />
    </div>
    """
  end

  # ── Helpers ─────────────────────────────────────────────────────────────

  defp health_value(%{} = health, fun), do: fun.(health)
  defp health_value(_health, _fun), do: "—"

  defp status_value(%{} = status, fun), do: fun.(status)
  defp status_value(_status, _fun), do: "—"

  defp status_hint(%{} = status, fun), do: fun.(status)
  defp status_hint(_status, _fun), do: nil

  defp provider_hint(%{provider: true, provider_name: provider, model: model}),
    do: "#{provider || "?"} · #{model || "?"} has a usable credential"

  defp provider_hint(%{reason: :missing_default_provider}), do: "No default provider is set"
  defp provider_hint(%{reason: :missing_default_model}), do: "No default model is set"

  defp provider_hint(%{reason: :model_provider_mismatch}),
    do: "Default model belongs to another provider"

  defp provider_hint(%{reason: :credential_not_usable}),
    do: "Default provider has no usable credential"

  defp provider_hint(_readiness), do: "Default provider and model with a usable credential"

  defp overall_tone("pass"), do: "success"
  defp overall_tone("warn"), do: "warning"
  defp overall_tone(_overall), do: "danger"

  defp overall_label("pass"), do: "All checks passed"
  defp overall_label("warn"), do: "Warnings"
  defp overall_label(_overall), do: "Failures"

  defp check_icon("pass"), do: "check-circle"
  defp check_icon("warn"), do: "alert-triangle"
  defp check_icon("fail"), do: "x-circle"
  defp check_icon(_status), do: "circle-dot"

  defp check_color("pass"), do: "text-success"
  defp check_color("warn"), do: "text-warning"
  defp check_color("fail"), do: "text-danger"
  defp check_color(_status), do: "text-subtle"

  defp level_label("all"), do: "All"
  defp level_label("info"), do: "Info+"
  defp level_label("warning"), do: "Warn+"
  defp level_label("error"), do: "Error"

  defp level_color(level) when level in ~w(error critical alert emergency), do: "text-danger"
  defp level_color("warning"), do: "text-warning"
  defp level_color("debug"), do: "text-subtle"
  defp level_color(_level), do: "text-info"

  defp log_time(nil), do: "--:--:--"

  defp log_time(ms) do
    ms |> DateTime.from_unix!(:millisecond) |> Calendar.strftime("%H:%M:%S")
  rescue
    _ -> "--:--:--"
  end

  @doc false
  def summary_text(assigns) do
    status = assigns.status
    health = assigns.health
    readiness = assigns.readiness
    doctor = assigns.doctor

    lines =
      [
        "Lemon diagnostics (#{DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()})",
        if(is_map(status),
          do:
            "version #{status.version || "?"} · OTP #{status.otp || "?"} · Elixir #{status.elixir}",
          else: "status: unavailable"
        ),
        if(is_map(health),
          do:
            "health: #{if health.ok, do: "ok", else: "degraded"} · uptime #{duration(health.uptime_ms)} · memory #{round(health.memory_mb)} MB · schedulers #{health.schedulers}",
          else: "health: unavailable"
        ),
        if(is_map(status),
          do:
            "runs: #{status.active_runs} active, #{status.queued_runs} queued, #{status.completed_today} today, #{status.failed_today} failed today · clients #{status.clients} · nodes #{status.nodes} · channels #{length(status.channels_connected)}/#{length(status.channels_configured)} connected · skills #{status.skills_enabled}/#{status.skills_installed} enabled",
          else: nil
        ),
        if(is_map(status),
          do:
            "beam: processes #{elem(status.processes, 0)}/#{elem(status.processes, 1)} · ports #{elem(status.ports, 0)}/#{elem(status.ports, 1)} · atoms #{elem(status.atoms, 0)}/#{elem(status.atoms, 1)} · run queue #{status.run_queue}",
          else: nil
        ),
        if(is_map(readiness),
          do:
            "setup: config #{mark(readiness.config)} · secrets #{mark(readiness.secrets)} · provider #{mark(readiness.provider)}#{if readiness.reason, do: " (#{readiness.reason})"}",
          else: "setup: unavailable"
        ),
        if(is_map(doctor),
          do:
            "doctor: #{doctor.overall} — #{doctor.counts["pass"]} pass, #{doctor.counts["warn"]} warn, #{doctor.counts["fail"]} fail, #{doctor.counts["skip"]} skip",
          else: "doctor: not run"
        )
      ] ++
        if(is_map(doctor),
          do:
            doctor.checks
            |> Enum.filter(&(&1.status in ~w(fail warn)))
            |> Enum.map(&"  [#{&1.status}] #{&1.name}: #{&1.message}"),
          else: []
        ) ++
        [
          "logs: " <>
            (assigns.logs
             |> Enum.frequencies_by(& &1.level)
             |> Enum.map_join(", ", fn {level, count} -> "#{count} #{level}" end)
             |> then(&if(&1 == "", do: "none", else: &1)))
        ]

    lines |> Enum.reject(&is_nil/1) |> Enum.join("\n")
  end

  defp mark(true), do: "ok"
  defp mark(_), do: "pending"
end
