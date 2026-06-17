defmodule LemonSimUi.Live.Components.TcgShopBoard do
  @moduledoc false

  use Phoenix.Component

  alias LemonCore.MapHelpers
  alias LemonSim.Examples.TcgShop.Performance

  attr(:world, :map, required: true)
  attr(:interactive, :boolean, default: false)

  def render(assigns) do
    scorecard = Performance.scorecard(assigns.world)
    assigns = assign(assigns, scorecard: scorecard)

    ~H"""
    <div class="space-y-5">
      <div class="rounded-xl border border-amber-500/25 bg-slate-950/80 overflow-hidden shadow-[0_0_32px_rgba(245,158,11,0.12)]">
        <div class="px-5 py-4 border-b border-amber-500/20 bg-slate-900/70 flex flex-wrap items-center justify-between gap-3">
          <div>
            <div class="text-[10px] uppercase tracking-[0.24em] text-amber-300 font-mono">Local Game Store</div>
            <h2 class="text-2xl font-bold text-white">TCG Shop</h2>
          </div>
          <div class="grid grid-cols-2 sm:grid-cols-4 gap-2 text-right">
            <.metric label="Day" value={"#{get(@world, :day_number, 1)}/#{get(@world, :max_days, 14)}"} />
            <.metric label="Cash" value={"$#{money(get(@world, :bank_balance, 0.0))}"} />
            <.metric label="Net Worth" value={"$#{money(@scorecard.net_worth)}"} />
            <.metric label="Rating" value={to_string(get(@world, :online_rating, 4.3))} />
          </div>
        </div>

        <div class="p-5 grid grid-cols-1 xl:grid-cols-12 gap-5">
          <div class="xl:col-span-8 space-y-4">
            <div class="grid grid-cols-1 md:grid-cols-2 gap-3">
              <%= for {line_id, item} <- inventory_rows(@world) do %>
                <% line = catalog_line(@world, line_id) %>
                <div class={[
                  "rounded-lg border p-3 bg-slate-900/70",
                  franchise_border(get(line, :franchise, ""))
                ]}>
                  <div class="flex items-start justify-between gap-3">
                    <div class="min-w-0">
                      <div class="text-[10px] uppercase tracking-widest text-slate-400 font-mono">{get(line, :franchise, "Unknown")}</div>
                      <div class="font-semibold text-slate-100 truncate">{get(line, :name, line_id)}</div>
                    </div>
                    <div class="text-right shrink-0">
                      <div class="text-xl font-bold text-white">{get(item, :on_hand, 0)}</div>
                      <div class="text-[10px] text-slate-500">on hand</div>
                    </div>
                  </div>
                  <div class="mt-3 grid grid-cols-3 gap-2 text-xs">
                    <div>
                      <div class="text-slate-500">Shelf</div>
                      <div class="text-emerald-300 font-mono">$#{money(get(item, :price, 0.0))}</div>
                    </div>
                    <div>
                      <div class="text-slate-500">Market</div>
                      <div class="text-cyan-300 font-mono">$#{money(get(line, :market_price, 0.0))}</div>
                    </div>
                    <div>
                      <div class="text-slate-500">Velocity</div>
                      <div class="text-amber-300 font-mono">{get(line, :velocity, 0.0)}x</div>
                    </div>
                  </div>
                </div>
              <% end %>
            </div>

            <div class="grid grid-cols-1 md:grid-cols-3 gap-3">
              <.panel title="Singles Case">
                <% singles = get(@world, :singles_case, %{}) %>
                <div class="text-3xl font-bold text-white">{get(singles, :cards_on_hand, 0)}</div>
                <div class="text-xs text-slate-400">raw cards</div>
                <div class="mt-2 text-sm text-emerald-300 font-mono">$#{money(get(singles, :total_market_value, 0.0))}</div>
                <div class="text-xs text-slate-500">raw market value</div>
              </.panel>
              <.panel title="Pending">
                <div class="text-sm text-slate-300">{length(get(@world, :pending_deliveries, []))} deliveries</div>
                <div class="text-sm text-slate-300">{length(get(@world, :pending_grading, []))} grading orders</div>
                <div class="mt-2 text-xs text-slate-500">Distribution and grading delays resolve on next-day ticks.</div>
              </.panel>
              <.panel title="Score">
                <div class="text-sm text-slate-300">ROI <span class="font-mono text-amber-300">{money(@scorecard.roi_pct)}%</span></div>
                <div class="text-sm text-slate-300">Reputation <span class="font-mono text-cyan-300">{@scorecard.reputation}</span></div>
                <div class="text-sm text-slate-300">Events <span class="font-mono text-fuchsia-300">{@scorecard.events_hosted}</span></div>
              </.panel>
            </div>
          </div>

          <div class="xl:col-span-4 space-y-4">
            <.panel title="Market Pulse">
              <% pulse = List.last(get(@world, :market_pulses, [])) || %{} %>
              <div class="text-lg font-semibold text-white">{get(pulse, :featured_franchise, "Unknown")}</div>
              <div class="text-sm text-amber-300 font-mono">{get(pulse, :buzz_multiplier, 1.0)}x buzz</div>
              <p class="mt-2 text-sm text-slate-400">{get(pulse, :note, "")}</p>
            </.panel>

            <.panel title="Customer Queue">
              <div class="space-y-2">
                <%= for customer <- Enum.take(get(@world, :customer_queue, []), 5) do %>
                  <div class="rounded border border-slate-700/70 bg-slate-950/60 p-2">
                    <div class="text-xs uppercase tracking-wider text-cyan-300">{get(customer, :type, "customer")}</div>
                    <div class="text-sm text-slate-200">{get(customer, :need, "")}</div>
                  </div>
                <% end %>
              </div>
            </.panel>

            <.panel title="Recent Activity">
              <div class="space-y-2">
                <%= for sale <- Enum.take(Enum.reverse(get(@world, :sales_history, [])), 6) do %>
                  <div class="flex justify-between gap-2 text-xs">
                    <span class="text-slate-400 truncate">{activity_label(sale)}</span>
                    <span class="text-emerald-300 font-mono shrink-0">$#{money(get(sale, :revenue, get(sale, :attach_sales, 0.0)))}</span>
                  </div>
                <% end %>
              </div>
            </.panel>
          </div>
        </div>
      </div>
    </div>
    """
  end

  attr(:label, :string, required: true)
  attr(:value, :string, required: true)

  defp metric(assigns) do
    ~H"""
    <div class="rounded-md border border-slate-700 bg-slate-950/60 px-3 py-2">
      <div class="text-[10px] uppercase tracking-widest text-slate-500">{@label}</div>
      <div class="text-sm font-mono text-slate-100 whitespace-nowrap">{@value}</div>
    </div>
    """
  end

  attr(:title, :string, required: true)
  slot(:inner_block, required: true)

  defp panel(assigns) do
    ~H"""
    <div class="rounded-lg border border-slate-700/80 bg-slate-900/70 p-4">
      <div class="text-[10px] uppercase tracking-[0.2em] text-slate-500 font-mono mb-3">{@title}</div>
      {render_slot(@inner_block)}
    </div>
    """
  end

  defp inventory_rows(world) do
    world
    |> get(:inventory, %{})
    |> Enum.sort_by(fn {line_id, _item} -> line_id end)
  end

  defp catalog_line(world, line_id) do
    world
    |> get(:catalog, %{})
    |> Map.get(line_id, %{})
  end

  defp franchise_border("Pokemon"), do: "border-yellow-400/35"
  defp franchise_border("Yu-Gi-Oh!"), do: "border-violet-400/35"
  defp franchise_border("One Piece"), do: "border-red-400/35"
  defp franchise_border("Dragon Ball Super"), do: "border-orange-400/35"
  defp franchise_border(_), do: "border-cyan-400/25"

  defp activity_label(sale) do
    get(sale, :line_id, get(sale, :game, get(sale, :packing_quality, "shop activity")))
  end

  defp get(map, key, default) when is_map(map), do: MapHelpers.get_key(map, key) || default
  defp get(_map, _key, default), do: default

  defp money(value), do: :erlang.float_to_binary((value || 0) + 0.0, decimals: 2)
end
