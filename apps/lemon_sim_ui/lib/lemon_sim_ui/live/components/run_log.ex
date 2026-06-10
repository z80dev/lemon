defmodule LemonSimUi.Live.Components.RunLog do
  use Phoenix.Component

  alias LemonCore.MapHelpers

  attr(:state, :map, required: true)
  attr(:running, :boolean, default: nil)

  def render(assigns) do
    world = assigns.state.world
    events = assigns.state.recent_events |> List.wrap() |> Enum.take(-14) |> Enum.reverse()
    plan_history = assigns.state.plan_history |> List.wrap() |> Enum.take(-10) |> Enum.reverse()
    runner_errors = MapHelpers.get_key(world, :runner_errors) || []
    decision_insights = decision_insights(world, events, runner_errors)

    assigns =
      assigns
      |> assign(:status, MapHelpers.get_key(world, :status) || "in_progress")
      |> assign(:phase, MapHelpers.get_key(world, :phase) || "unknown")
      |> assign(:day_number, MapHelpers.get_key(world, :day_number) || 1)
      |> assign(:max_days, MapHelpers.get_key(world, :max_days) || 30)
      |> assign(:time_minutes, MapHelpers.get_key(world, :time_minutes) || 0)
      |> assign(:active_actor, MapHelpers.get_key(world, :active_actor_id) || "operator")
      |> assign(:bank_balance, MapHelpers.get_key(world, :bank_balance) || 0)
      |> assign(:cash_in_machine, MapHelpers.get_key(world, :cash_in_machine) || 0)
      |> assign(:process_status, process_status(assigns[:running]))
      |> assign(:events, events)
      |> assign(:plan_history, plan_history)
      |> assign(:runner_errors, runner_errors)
      |> assign(:decision_insights, decision_insights)

    ~H"""
    <section class="border-t border-emerald-900/60 bg-slate-950/95">
      <div class="px-4 md:px-6 py-4 grid grid-cols-1 xl:grid-cols-12 gap-4">
        <div class="xl:col-span-3 rounded-lg border border-emerald-900/60 bg-[#0d1712] p-4">
          <div class="text-[10px] font-bold tracking-widest text-emerald-400 uppercase mb-3">
            Current Status
          </div>
          <div class="grid grid-cols-2 gap-3 text-xs font-mono">
            <.status_metric label="Day" value={"#{@day_number}/#{@max_days}"} />
            <.status_metric label="Time" value={format_time(@time_minutes)} />
            <.status_metric label="Phase" value={humanize(@phase)} />
            <.status_metric label="Actor" value={humanize(@active_actor)} />
            <.status_metric label="Process" value={@process_status} />
            <.status_metric label="World" value={humanize(@status)} />
            <.status_metric label="Bank" value={"$#{format_money(@bank_balance)}"} />
            <.status_metric label="Machine" value={"$#{format_money(@cash_in_machine)}"} />
          </div>
          <div class="mt-4 flex items-center gap-2">
            <span class={["w-2 h-2 rounded-full", status_dot(@status)]}></span>
            <span class="text-[11px] font-bold uppercase tracking-widest text-slate-300">
              {humanize(@status)}
            </span>
          </div>
          <div :if={@runner_errors != []} class="mt-4 rounded border border-red-500/30 bg-red-950/20 p-3">
            <div class="text-[10px] font-bold uppercase tracking-widest text-red-300 mb-1">
              Latest Error
            </div>
            <% latest_error = List.last(@runner_errors) %>
            <div class="text-[11px] text-red-200 font-mono leading-relaxed">
              {error_message(latest_error)}
            </div>
          </div>
          <div class="mt-4 rounded border border-amber-500/25 bg-amber-950/10 p-3">
            <div class="text-[10px] font-bold uppercase tracking-widest text-amber-300 mb-2">
              Decision Pressure
            </div>
            <div class="space-y-2">
              <div :if={@decision_insights == []} class="text-[11px] text-slate-500 italic">
                No pressure signals yet.
              </div>
              <%= for insight <- @decision_insights do %>
                <div class="flex items-start gap-2 text-[11px] text-amber-100 leading-relaxed">
                  <span class={["mt-1 h-1.5 w-1.5 rounded-full shrink-0", insight_dot(insight.severity)]}></span>
                  <span>{insight.text}</span>
                </div>
              <% end %>
            </div>
          </div>
        </div>

        <div class="xl:col-span-5 rounded-lg border border-emerald-900/60 bg-[#0d1712] overflow-hidden">
          <div class="px-4 py-3 border-b border-emerald-900/50 bg-[#0a120e] flex items-center justify-between gap-3">
            <div class="text-[10px] font-bold tracking-widest text-cyan-300 uppercase">
              Model Decision Trace
            </div>
            <div class="text-[10px] text-slate-500 font-mono">{length(@plan_history)} entries</div>
          </div>
          <div id="run-log-plan-scroll" phx-hook="ScrollBottom" class="scroll-bottom max-h-80 overflow-y-auto p-3 space-y-2">
            <div :if={@plan_history == []} class="text-xs text-slate-600 italic px-1 py-2">
              Waiting for the first model decision.
            </div>
            <%= for {step, idx} <- Enum.with_index(@plan_history) do %>
              <article class="rounded border border-cyan-500/20 bg-cyan-950/10 px-3 py-2">
                <div class="flex items-start justify-between gap-3">
                  <div class="text-[11px] font-semibold text-cyan-100 leading-relaxed">
                    {step_summary(step)}
                  </div>
                  <span class="text-[10px] text-cyan-600 font-mono shrink-0">-{idx + 1}</span>
                </div>
                <div :if={step_rationale(step)} class="mt-2 text-[11px] text-slate-300/90 font-mono leading-relaxed whitespace-pre-wrap">
                  {step_rationale(step)}
                </div>
                <div :if={step_meta_line(step)} class="mt-2 text-[10px] text-slate-500 font-mono">
                  {step_meta_line(step)}
                </div>
                <div :if={step_badges(step) != []} class="mt-2 flex flex-wrap gap-1.5">
                  <%= for badge <- step_badges(step) do %>
                    <span class="rounded border border-cyan-500/20 bg-cyan-500/10 px-1.5 py-0.5 text-[9px] font-mono uppercase tracking-wide text-cyan-200">
                      {badge}
                    </span>
                  <% end %>
                </div>
              </article>
            <% end %>
          </div>
        </div>

        <div class="xl:col-span-4 rounded-lg border border-emerald-900/60 bg-[#0d1712] overflow-hidden">
          <div class="px-4 py-3 border-b border-emerald-900/50 bg-[#0a120e] flex items-center justify-between gap-3">
            <div class="text-[10px] font-bold tracking-widest text-emerald-300 uppercase">
              Live Event Feed
            </div>
            <div class="text-[10px] text-slate-500 font-mono">{length(@events)} events</div>
          </div>
          <div id="run-log-event-scroll" phx-hook="ScrollBottom" class="scroll-bottom max-h-80 overflow-y-auto p-3 space-y-2">
            <div :if={@events == []} class="text-xs text-slate-600 italic px-1 py-2">
              No events yet.
            </div>
            <%= for {event, idx} <- Enum.with_index(@events) do %>
              <article class="rounded border border-emerald-500/20 bg-emerald-950/10 px-3 py-2">
                <div class="flex items-start justify-between gap-3">
                  <div class="min-w-0">
                    <div class="text-[11px] font-bold uppercase tracking-wide text-emerald-200">
                      {format_kind(event_kind(event))}
                    </div>
                    <div class="mt-1 text-[11px] text-slate-300 font-mono leading-relaxed">
                      {event_summary(event)}
                    </div>
                  </div>
                  <span class="text-[10px] text-emerald-700 font-mono shrink-0">-{idx + 1}</span>
                </div>
              </article>
            <% end %>
          </div>
        </div>
      </div>
    </section>
    """
  end

  attr(:label, :string, required: true)
  attr(:value, :string, required: true)

  defp status_metric(assigns) do
    ~H"""
    <div class="rounded border border-emerald-900/50 bg-black/20 p-2 min-w-0">
      <div class="text-[9px] uppercase tracking-widest text-slate-500 truncate">{@label}</div>
      <div class="mt-1 text-slate-100 truncate">{@value}</div>
    </div>
    """
  end

  defp step_summary(step), do: get(step, :summary, "Step")
  defp step_rationale(step), do: step |> get(:rationale, nil) |> present_string()

  defp step_meta_line(step) do
    meta = get(step, :meta, %{})
    actor = meta |> get(:actor, nil) |> present_string()
    tools = meta |> get(:tools, []) |> List.wrap() |> Enum.reject(&is_nil/1)
    events = meta |> get(:events, []) |> List.wrap() |> Enum.reject(&is_nil/1)

    parts =
      []
      |> maybe_part("actor", actor)
      |> maybe_part("tools", Enum.join(tools, ", "))
      |> maybe_part("events", Enum.join(events, ", "))

    case parts do
      [] -> nil
      _ -> Enum.join(parts, " | ")
    end
  end

  defp event_kind(event), do: get(event, :kind, "event")
  defp event_payload(event), do: get(event, :payload, %{})

  defp event_summary(event) do
    payload = event_payload(event)

    cond do
      event_kind(event) == "action_rejected" ->
        "Rejected: #{get(payload, :reason, "unknown reason")}"

      event_kind(event) == "supplier_reply_received" ->
        supplier = get(payload, :supplier_id, get(payload, :from, "supplier"))
        message = get(payload, :message, get(payload, :body, "reply received"))
        "#{supplier}: #{message}"

      event_kind(event) == "place_supplier_order" ->
        "#{get(payload, :quantity, "?")}x #{humanize(get(payload, :item_id, "item"))} from #{get(payload, :supplier_id, "supplier")}"

      event_kind(event) == "sale_realized" ->
        "#{get(payload, :quantity, "?")}x #{humanize(get(payload, :item_id, "item"))} sold from #{get(payload, :slot_id, "?")} for $#{format_money(get(payload, :revenue, 0))}"

      text = get(payload, :summary, nil) ->
        text

      text = get(payload, :message, nil) ->
        text

      reason = get(payload, :reason, nil) ->
        "Reason: #{humanize(reason)}"

      map_size(payload) == 0 ->
        "No payload"

      true ->
        payload
        |> Enum.take(4)
        |> Enum.map(fn {key, value} -> "#{key}=#{format_value(value)}" end)
        |> Enum.join(" ")
    end
    |> truncate(220)
  end

  defp error_message(error), do: error |> get(:message, inspect(error)) |> truncate(220)

  defp decision_insights(world, events, runner_errors) do
    []
    |> maybe_insight(latest_rejection(events))
    |> maybe_insight(latest_runner_error(runner_errors))
    |> maybe_insight(pending_delivery_insight(world))
    |> maybe_insight(open_reminder_insight(world))
    |> maybe_insight(stockout_insight(world))
    |> maybe_insight(customer_complaint_insight(world))
    |> Enum.take(6)
  end

  defp latest_rejection(events) do
    events
    |> Enum.find(&(event_kind(&1) == "action_rejected"))
    |> case do
      nil ->
        nil

      event ->
        %{
          severity: :high,
          text:
            "Last rejected action: #{event_payload(event) |> get(:reason, "unknown reason") |> truncate(140)}"
        }
    end
  end

  defp latest_runner_error([]), do: nil

  defp latest_runner_error(errors) do
    %{
      severity: :high,
      text: "Runner issue: #{errors |> List.wrap() |> List.last() |> error_message()}"
    }
  end

  defp pending_delivery_insight(world) do
    deliveries = MapHelpers.get_key(world, :pending_deliveries) || []

    if deliveries == [] do
      nil
    else
      soonest =
        deliveries
        |> Enum.map(&get(&1, :delivery_day, get(&1, :eta_day, nil)))
        |> Enum.reject(&is_nil/1)
        |> Enum.min(fn -> "?" end)

      %{
        severity: :medium,
        text:
          "#{length(deliveries)} supplier delivery batch(es) pending; next ETA day #{soonest}."
      }
    end
  end

  defp open_reminder_insight(world) do
    reminders =
      world
      |> MapHelpers.get_key(:reminders)
      |> List.wrap()
      |> Enum.reject(&(get(&1, :status, "open") == "done"))

    case reminders do
      [] ->
        nil

      [reminder | _] ->
        %{
          severity: :medium,
          text:
            "Open reminder D#{get(reminder, :day, "?")}: #{get(reminder, :text, "") |> truncate(120)}"
        }
    end
  end

  defp stockout_insight(world) do
    machine = MapHelpers.get_key(world, :machine) || %{}
    slots = get(machine, :slots, %{})

    stockouts =
      slots
      |> Enum.count(fn {_slot_id, slot} ->
        get(slot, :item_id, nil) != nil and get(slot, :inventory, 0) <= 0
      end)

    cond do
      stockouts > 0 ->
        %{severity: :high, text: "#{stockouts} configured slot(s) are stocked out."}

      true ->
        nil
    end
  end

  defp customer_complaint_insight(world) do
    complaints = MapHelpers.get_key(world, :customer_complaints) || []

    if complaints == [] do
      nil
    else
      latest = List.last(complaints)

      %{
        severity: :medium,
        text: "Latest complaint: #{get(latest, :reason, "customer complaint") |> humanize()}."
      }
    end
  end

  defp maybe_insight(insights, nil), do: insights
  defp maybe_insight(insights, insight), do: insights ++ [insight]

  defp step_badges(step) do
    meta = get(step, :meta, %{})

    []
    |> maybe_badge(meta |> get(:day, nil), "D")
    |> maybe_badge(meta |> get(:turn, nil), "T")
    |> maybe_badge(meta |> get(:phase, nil), "")
  end

  defp maybe_badge(badges, nil, _prefix), do: badges
  defp maybe_badge(badges, "", _prefix), do: badges
  defp maybe_badge(badges, value, ""), do: badges ++ [humanize(value)]
  defp maybe_badge(badges, value, prefix), do: badges ++ ["#{prefix}#{value}"]

  defp maybe_part(parts, _label, nil), do: parts
  defp maybe_part(parts, _label, ""), do: parts
  defp maybe_part(parts, label, value), do: parts ++ ["#{label}=#{value}"]

  defp status_dot("in_progress"), do: "bg-red-500 animate-pulse"
  defp status_dot("complete"), do: "bg-emerald-400"
  defp status_dot(_), do: "bg-slate-500"

  defp insight_dot(:high), do: "bg-red-400"
  defp insight_dot(:medium), do: "bg-amber-300"
  defp insight_dot(_), do: "bg-slate-500"

  defp process_status(true), do: "Running"
  defp process_status(false), do: "Stopped"
  defp process_status(_), do: "Unknown"

  defp format_kind(kind), do: kind |> to_string() |> humanize()

  defp humanize(value) do
    value
    |> to_string()
    |> String.replace("_", " ")
    |> String.split(" ", trim: true)
    |> Enum.map(&String.capitalize/1)
    |> Enum.join(" ")
  end

  defp format_time(minutes) when is_integer(minutes) do
    hour = div(minutes, 60)
    minute = rem(minutes, 60)
    "#{pad2(hour)}:#{pad2(minute)}"
  end

  defp format_time(_), do: "00:00"

  defp format_money(value) when is_number(value),
    do: :erlang.float_to_binary(value / 1, decimals: 2)

  defp format_money(value), do: value |> to_string() |> truncate(16)

  defp format_value(value) when is_binary(value), do: value |> humanize() |> truncate(80)
  defp format_value(value) when is_number(value), do: to_string(value)
  defp format_value(value) when is_atom(value), do: humanize(value)
  defp format_value(value) when is_map(value), do: inspect(value, limit: 3, printable_limit: 80)
  defp format_value(value) when is_list(value), do: inspect(value, limit: 3, printable_limit: 80)
  defp format_value(value), do: value |> to_string() |> truncate(80)

  defp present_string(value) when is_binary(value) do
    value = String.trim(value)
    if value == "", do: nil, else: value
  end

  defp present_string(nil), do: nil
  defp present_string(value), do: value |> to_string() |> present_string()

  defp truncate(value, max) when is_binary(value) and byte_size(value) > max do
    String.slice(value, 0, max) <> "..."
  end

  defp truncate(value, _max), do: value

  defp pad2(value) when value < 10, do: "0#{value}"
  defp pad2(value), do: to_string(value)

  defp get(map, key, default) when is_map(map) and is_atom(key),
    do: Map.get(map, key, Map.get(map, Atom.to_string(key), default))

  defp get(map, key, default), do: MapHelpers.get_key(map, key) || default
end
