defmodule LemonWeb.UsageLive do
  @moduledoc """
  `/usage`: token and cost totals for today, 7 or 30 days.

  Reads `usage.cost` (per-day records written by `LemonCore.UsageLedger` when a
  run finalizes: providers, models, top sessions, daily series) and
  `usage.status` (today's totals and configured quotas). Only identifiers and
  numbers are projected; charts are plain CSS bars. Refreshes every 30 seconds
  while connected.
  """

  use LemonWeb, :live_view

  alias LemonWeb.Rpc

  @ranges %{"today" => 1, "7d" => 7, "30d" => 30}
  @refresh_ms 30_000
  @max_rows 50
  @label ~r/^[\w.:@\/+-][\w.:@\/+ -]{0,127}$/u

  @impl true
  def mount(_params, _session, socket) do
    _ = if connected?(socket), do: schedule_refresh()

    {:ok,
     assign(socket,
       nav: :usage,
       page_title: "Usage · Lemon",
       page_heading: "Usage",
       range: "7d",
       metric: nil,
       usage: nil,
       usage_error: nil,
       quota: nil
     )}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    range = if Map.has_key?(@ranges, params["range"]), do: params["range"], else: "7d"
    metric = if params["metric"] in ~w(cost tokens), do: params["metric"]

    {:noreply, socket |> assign(range: range, metric: metric) |> load()}
  end

  @impl true
  def handle_info(:refresh, socket) do
    schedule_refresh()
    {:noreply, load(socket)}
  end

  @impl true
  def handle_event("refresh", _params, socket), do: {:noreply, load(socket)}

  defp schedule_refresh, do: Process.send_after(self(), :refresh, @refresh_ms)

  # ── Data ────────────────────────────────────────────────────────────────

  defp load(socket) do
    days = Map.fetch!(@ranges, socket.assigns.range)
    today = Date.utc_today()
    start = Date.add(today, 1 - days)

    socket =
      case Rpc.call("usage.cost", %{
             "startDate" => Date.to_iso8601(start),
             "endDate" => Date.to_iso8601(today)
           }) do
        {:ok, %{} = result} ->
          assign(socket, usage: project_usage(result, start, today), usage_error: nil)

        {:error, error} ->
          assign(socket, usage: nil, usage_error: Rpc.message(error))
      end

    case Rpc.call("usage.status", %{}) do
      {:ok, %{} = status} -> assign(socket, :quota, project_quota(status))
      _ -> assign(socket, :quota, :unavailable)
    end
  end

  defp project_usage(result, start, today) do
    tokens = result["totalTokens"] || %{}
    daily = result |> list("dailyUsage") |> Map.new(&{&1["date"], &1})

    %{
      cost: number(result["totalCost"]),
      requests: integer(result["totalRequests"]),
      input: integer(tokens["input"] || tokens[:input]),
      output: integer(tokens["output"] || tokens[:output]),
      providers: result |> list("providers") |> Enum.flat_map(&row(&1, ["provider"])),
      models: result |> list("models") |> Enum.flat_map(&row(&1, ["provider", "model"])),
      sessions: result |> list("sessions") |> Enum.flat_map(&row(&1, ["sessionKey"])),
      sessions_omitted: integer(result["sessionsOmitted"]),
      days:
        Enum.map(Date.range(start, today), fn date ->
          key = Date.to_iso8601(date)
          day = daily[key] || %{}

          %{
            date: date,
            cost: number(day["cost"]),
            requests: integer(day["requests"]),
            input: integer(day["inputTokens"]),
            output: integer(day["outputTokens"])
          }
        end)
    }
  end

  defp list(result, key) do
    case result[key] do
      rows when is_list(rows) -> rows |> Enum.filter(&is_map/1) |> Enum.take(@max_rows)
      _ -> []
    end
  end

  defp row(row, label_keys) do
    labels = Enum.map(label_keys, &safe_label(row[&1]))

    if Enum.any?(labels, &is_nil/1) do
      []
    else
      [
        label_keys
        |> Enum.map(&String.to_atom(Macro.underscore(&1)))
        |> Enum.zip(labels)
        |> Map.new()
        |> Map.merge(%{
          cost: number(row["cost"]),
          requests: integer(row["requests"]),
          input: integer(row["inputTokens"]),
          output: integer(row["outputTokens"]),
          last_at_ms: if(is_integer(row["lastAtMs"]), do: row["lastAtMs"])
        })
      ]
    end
  end

  defp project_quota(status) do
    summary = if is_map(status["summary"]), do: status["summary"], else: %{}
    quotas = if is_map(status["quotas"]), do: status["quotas"], else: %{}
    tokens = if is_map(status["tokens"]), do: status["tokens"], else: %{}

    %{
      status:
        if(summary["status"] in ~w(within_limits over_limit unlimited),
          do: summary["status"],
          else: "unknown"
        ),
      runs: integer(status["runs"]),
      tokens: integer(tokens["input"]) + integer(tokens["output"]),
      cost: number(status["cost"]),
      limits: [
        {"Runs", integer(status["runs"]), quotas["runsLimit"], &Integer.to_string/1},
        {"Tokens", integer(tokens["input"]) + integer(tokens["output"]), quotas["tokensLimit"],
         &compact_number/1},
        {"Cost", number(status["cost"]), quotas["costLimit"], &usd/1}
      ]
    }
  end

  defp safe_label(value) when is_binary(value) do
    if Regex.match?(@label, value), do: value
  end

  defp safe_label(_value), do: nil

  defp number(value) when is_number(value) and value >= 0, do: value * 1.0
  defp number(_value), do: 0.0

  defp integer(value) when is_integer(value) and value >= 0, do: value
  defp integer(_value), do: 0

  # ── Render ──────────────────────────────────────────────────────────────

  @impl true
  def render(assigns) do
    assigns =
      assign(assigns, :chart_metric, chart_metric(assigns.metric, assigns.usage))

    ~H"""
    <.page>
      <.page_header title="Usage" icon="bar-chart" subtitle="Tokens and spend recorded when runs finish. Times are UTC.">
        <:actions>
          <div class="segmented" role="group" aria-label="Range">
            <.link
              :for={{id, label} <- [{"today", "Today"}, {"7d", "7 days"}, {"30d", "30 days"}]}
              patch={range_path(id, @metric)}
              aria-pressed={to_string(@range == id)}
              id={"range-#{id}"}
            >
              {label}
            </.link>
          </div>
          <.button icon="refresh" size="sm" variant="ghost" phx-click="refresh" aria-label="Refresh usage" icon_only />
        </:actions>
      </.page_header>

      <.callout :if={@usage_error} tone="danger" title="Usage data is unavailable" id="usage-unavailable" class="mb-4">
        {@usage_error} Totals below are not shown until the runtime answers again.
      </.callout>

      <section aria-label="Totals" class="mb-5 grid grid-cols-2 gap-3 lg:grid-cols-4">
        <.stat label="Spend" icon="gauge" value={@usage && usd(@usage.cost) || "—"} hint={range_hint(@range)} />
        <.stat label="Runs" icon="activity" value={@usage && compact_number(@usage.requests) || "—"} hint="Finished runs" />
        <.stat label="Input tokens" icon="arrow-right" value={@usage && compact_number(@usage.input) || "—"} hint="Incl. cached input" />
        <.stat label="Output tokens" icon="corner-down-left" value={@usage && compact_number(@usage.output) || "—"} hint="Model output" />
      </section>

      <div :if={@usage && @usage.requests == 0} id="usage-empty">
        <.empty_state
          icon="bar-chart"
          title="No usage recorded in this period"
          description="Usage appears here once a run finishes. Start a chat to see tokens and spend by model, provider and session."
        >
          <.button navigate={~p"/"} icon="message-square" variant="primary">Start a chat</.button>
        </.empty_state>
      </div>

      <div :if={@usage && @usage.requests > 0} class="grid gap-4 xl:grid-cols-3">
        <.card class="xl:col-span-2" id="usage-chart-card">
          <:header>{if @range == "today", do: "Today by model", else: "Daily #{metric_label(@chart_metric)}"}</:header>
          <:actions>
            <div class="segmented" role="group" aria-label="Chart metric">
              <.link patch={range_path(@range, "cost")} aria-pressed={to_string(@chart_metric == "cost")}>Spend</.link>
              <.link patch={range_path(@range, "tokens")} aria-pressed={to_string(@chart_metric == "tokens")}>Tokens</.link>
            </div>
          </:actions>
          <.bar_chart
            :if={@range != "today"}
            id="usage-daily-chart"
            bars={Enum.map(@usage.days, &day_bar(&1, @chart_metric))}
            metric={@chart_metric}
            dense={@range == "30d"}
          />
          <.share_list :if={@range == "today"} id="usage-today-models" rows={model_rows(@usage.models)} metric={@chart_metric} />
        </.card>

        <.card id="usage-quota-card">
          <:header>Today &amp; quotas</:header>
          <.quota_panel quota={@quota} />
        </.card>

        <.card class="xl:col-span-2" id="usage-models-card" body_class="">
          <:header>By model</:header>
          <.usage_table id="usage-models" rows={@usage.models} total={@usage} kind={:model} />
        </.card>

        <.card id="usage-providers-card">
          <:header>By provider</:header>
          <.share_list id="usage-providers" rows={provider_rows(@usage.providers)} metric={@chart_metric} />
        </.card>

        <.card class="xl:col-span-3" id="usage-sessions-card" body_class="">
          <:header>Top sessions</:header>
          <.usage_table id="usage-sessions" rows={@usage.sessions} total={@usage} kind={:session} />
          <:footer :if={@usage.sessions_omitted > 0}>
            <p class="text-xs text-subtle">
              Showing the top {length(@usage.sessions)} sessions; {@usage.sessions_omitted} more are included in the totals.
            </p>
          </:footer>
        </.card>
      </div>
    </.page>
    """
  end

  attr(:id, :string, required: true)
  attr(:bars, :list, required: true)
  attr(:metric, :string, required: true)
  attr(:dense, :boolean, default: false)

  defp bar_chart(assigns) do
    max = assigns.bars |> Enum.map(& &1.value) |> Enum.max(fn -> 0 end)
    assigns = assign(assigns, max: max)

    ~H"""
    <figure id={@id} class="space-y-2">
      <div
        class="flex h-44 items-end gap-[3px] border-b border-line"
        role="img"
        aria-label={"Daily #{metric_label(@metric)} chart; values listed in the table below"}
      >
        <div :for={bar <- @bars} class="group relative flex h-full min-w-0 flex-1 flex-col justify-end">
          <div
            class={[
              "w-full rounded-t-sm transition-[height] duration-300",
              if(bar.value > 0, do: "bg-accent group-hover:bg-ring", else: "bg-surface-2")
            ]}
            style={"height: #{bar_height(bar.value, @max)}%"}
            title={"#{bar.label}: #{bar.display}"}
          >
          </div>
          <span class="pointer-events-none absolute -top-6 left-1/2 z-10 hidden -translate-x-1/2 whitespace-nowrap rounded border border-line bg-elevated px-1.5 py-0.5 text-2xs text-fg shadow-pop group-hover:block">
            {bar.display}
          </span>
        </div>
      </div>
      <div class="flex gap-[3px] text-2xs tabular-nums text-subtle" aria-hidden="true">
        <span :for={{bar, index} <- Enum.with_index(@bars)} class="min-w-0 flex-1 truncate text-center">
          {if not @dense or rem(length(@bars) - 1 - index, 5) == 0, do: bar.short}
        </span>
      </div>
      <figcaption class="sr-only">
        <table>
          <tr :for={bar <- @bars}><th scope="row">{bar.label}</th><td>{bar.display}</td></tr>
        </table>
      </figcaption>
    </figure>
    """
  end

  attr(:id, :string, required: true)
  attr(:rows, :list, required: true)
  attr(:metric, :string, required: true)

  defp share_list(assigns) do
    total = assigns.rows |> Enum.map(&metric_value(&1, assigns.metric)) |> Enum.sum()
    assigns = assign(assigns, total: total)

    ~H"""
    <ul id={@id} class="space-y-3">
      <li :if={@rows == []} class="py-4 text-center text-xs text-muted">Nothing recorded.</li>
      <li :for={row <- @rows} class="space-y-1">
        <div class="flex items-baseline justify-between gap-3 text-[13px]">
          <span class="min-w-0 truncate font-medium text-fg" title={row.label}>{row.label}</span>
          <span class="shrink-0 tabular-nums text-muted">{metric_display(row, @metric)}</span>
        </div>
        <.meter value={metric_value(row, @metric)} max={@total} label={"#{row.label} share"} />
      </li>
    </ul>
    """
  end

  attr(:id, :string, required: true)
  attr(:rows, :list, required: true)
  attr(:total, :map, required: true)
  attr(:kind, :atom, required: true)

  defp usage_table(assigns) do
    ~H"""
    <.table id={@id} rows={@rows} empty="Nothing recorded.">
      <:col :let={row} label={if @kind == :model, do: "Model", else: "Session"}>
        <div :if={@kind == :model} class="min-w-0">
          <p class="truncate font-mono text-xs text-fg">{row.model}</p>
          <p class="text-2xs text-subtle">{row.provider}</p>
        </div>
        <div :if={@kind == :session} class="min-w-0">
          <.link navigate={~p"/sessions/#{row.session_key}"} class="block max-w-[22rem] truncate font-mono text-xs text-fg hover:text-accent-text hover:underline">
            {row.session_key}
          </.link>
          <p :if={row.last_at_ms} class="text-2xs text-subtle">Last run {relative_time(row.last_at_ms)}</p>
        </div>
      </:col>
      <:col :let={row} label="Runs" class="text-right tabular-nums">{row.requests}</:col>
      <:col :let={row} label="Input" class="hidden text-right tabular-nums sm:table-cell">{compact_number(row.input)}</:col>
      <:col :let={row} label="Output" class="hidden text-right tabular-nums sm:table-cell">{compact_number(row.output)}</:col>
      <:col :let={row} label="Spend" class="text-right tabular-nums">{usd(row.cost)}</:col>
      <:col :let={row} label="Share" class="hidden w-32 md:table-cell">
        <.meter value={share_value(row, @total)} max={share_total(@total)} label="Share of period" />
      </:col>
    </.table>
    """
  end

  attr(:quota, :any, required: true)

  defp quota_panel(assigns) do
    ~H"""
    <div id="usage-quota">
      <p :if={@quota in [nil, :unavailable]} class="text-[13px] text-muted">Quota status is unavailable right now. Try again, or check /diagnostics.</p>
      <div :if={is_map(@quota)} class="space-y-4">
        <div class="flex items-center gap-2">
          <.badge tone={quota_tone(@quota.status)} icon={if @quota.status == "over_limit", do: "alert-triangle", else: "shield-check"}>
            {quota_label(@quota.status)}
          </.badge>
          <span class="text-xs text-subtle">today (UTC)</span>
        </div>
        <.key_value>
          <:item label="Runs">{@quota.runs}</:item>
          <:item label="Tokens">{compact_number(@quota.tokens)}</:item>
          <:item label="Spend">{usd(@quota.cost)}</:item>
        </.key_value>
        <div :for={{label, value, limit, format} <- @quota.limits} :if={is_number(limit)} class="space-y-1">
          <div class="flex justify-between text-xs">
            <span class="text-muted">{label}</span>
            <span class="tabular-nums text-fg">{format.(value)} / {format.(limit)}</span>
          </div>
          <.meter value={value} max={limit} auto_tone label={"#{label} quota"} />
        </div>
        <p :if={@quota.status == "unlimited"} class="text-xs text-subtle">
          No run, token or cost quota is configured for this runtime.
        </p>
      </div>
    </div>
    """
  end

  # ── Helpers ─────────────────────────────────────────────────────────────

  defp chart_metric(metric, _usage) when metric in ~w(cost tokens), do: metric
  defp chart_metric(_metric, %{cost: cost}) when cost > 0, do: "cost"
  defp chart_metric(_metric, _usage), do: "tokens"

  defp range_path(range, nil), do: ~p"/usage?#{[range: range]}"
  defp range_path(range, metric), do: ~p"/usage?#{[range: range, metric: metric]}"

  defp range_hint("today"), do: "Today"
  defp range_hint("7d"), do: "Last 7 days"
  defp range_hint("30d"), do: "Last 30 days"

  defp metric_label("cost"), do: "spend"
  defp metric_label(_metric), do: "tokens"

  defp day_bar(day, metric) do
    value = if metric == "cost", do: day.cost, else: day.input + day.output

    %{
      value: value,
      label: Calendar.strftime(day.date, "%a %b %-d"),
      short: Calendar.strftime(day.date, "%-d"),
      display:
        if(metric == "cost",
          do: "#{usd(day.cost)} · #{day.requests} runs",
          else: "#{compact_number(day.input + day.output)} tokens · #{day.requests} runs"
        )
    }
  end

  defp bar_height(_value, max) when max <= 0, do: 2
  defp bar_height(value, _max) when value <= 0, do: 2
  defp bar_height(value, max), do: max(Float.round(value * 100 / max, 1), 3)

  defp model_rows(models),
    do: Enum.map(models, &Map.put(&1, :label, "#{&1.provider}:#{&1.model}"))

  defp provider_rows(providers), do: Enum.map(providers, &Map.put(&1, :label, &1.provider))

  defp metric_value(row, "cost"), do: row.cost
  defp metric_value(row, _metric), do: row.input + row.output

  defp metric_display(row, "cost"), do: "#{usd(row.cost)} · #{row.requests} runs"

  defp metric_display(row, _metric),
    do: "#{compact_number(row.input + row.output)} tok · #{row.requests} runs"

  defp share_value(row, %{cost: cost}) when cost > 0, do: row.cost
  defp share_value(row, _total), do: row.input + row.output

  defp share_total(%{cost: cost}) when cost > 0, do: cost
  defp share_total(total), do: total.input + total.output

  defp quota_tone("over_limit"), do: "danger"
  defp quota_tone("within_limits"), do: "success"
  defp quota_tone(_status), do: "neutral"

  defp quota_label("over_limit"), do: "Over a quota"
  defp quota_label("within_limits"), do: "Within quotas"
  defp quota_label("unlimited"), do: "No quotas"
  defp quota_label(_status), do: "Unknown"
end
