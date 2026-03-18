defmodule LemonSimUi.Live.Components.VendingBenchBoard do
  use Phoenix.Component

  alias LemonCore.MapHelpers

  attr(:world, :map, required: true)
  attr(:interactive, :boolean, default: false)

  def render(assigns) do
    world = assigns.world

    status = MapHelpers.get_key(world, :status) || "in_progress"
    phase = MapHelpers.get_key(world, :phase) || "operating"
    day_number = MapHelpers.get_key(world, :day_number) || 1
    time_minutes = MapHelpers.get_key(world, :time_minutes) || 0
    max_days = MapHelpers.get_key(world, :max_days) || 30
    bank_balance = MapHelpers.get_key(world, :bank_balance) || 0
    cash_in_machine = MapHelpers.get_key(world, :cash_in_machine) || 0
    daily_fee = MapHelpers.get_key(world, :daily_fee) || 0
    machine = MapHelpers.get_key(world, :machine) || %{}
    slots = MapHelpers.get_key(machine, :slots) || %{}
    storage = MapHelpers.get_key(world, :storage) || %{}
    storage_inventory = MapHelpers.get_key(storage, :inventory) || %{}
    catalog = MapHelpers.get_key(world, :catalog) || %{}
    inbox = MapHelpers.get_key(world, :inbox) || []
    pending_deliveries = MapHelpers.get_key(world, :pending_deliveries) || []
    recent_sales = MapHelpers.get_key(world, :recent_sales) || []
    physical_worker_last_report = MapHelpers.get_key(world, :physical_worker_last_report)
    physical_worker_run_count = MapHelpers.get_key(world, :physical_worker_run_count) || 0
    weather = MapHelpers.get_key(world, :weather)
    season = MapHelpers.get_key(world, :season)
    weather_kind = get_val(weather, :kind, nil)
    season_name = get_val(season, :name, nil)

    # Time formatting
    time_display = format_time(time_minutes)

    # Slot grid keys in order
    slot_keys =
      for row <- ["A", "B", "C", "D"], col <- ["1", "2", "3"] do
        "#{row}#{col}"
      end

    # Recent sales (last 8)
    recent_sales_display =
      recent_sales
      |> Enum.reverse()
      |> Enum.take(8)
      |> Enum.reverse()

    # Recent inbox (last 6)
    inbox_display =
      inbox
      |> Enum.reverse()
      |> Enum.take(6)
      |> Enum.reverse()

    assigns =
      assigns
      |> assign(:status, status)
      |> assign(:phase, phase)
      |> assign(:day_number, day_number)
      |> assign(:time_display, time_display)
      |> assign(:max_days, max_days)
      |> assign(:bank_balance, bank_balance)
      |> assign(:cash_in_machine, cash_in_machine)
      |> assign(:daily_fee, daily_fee)
      |> assign(:slots, slots)
      |> assign(:slot_keys, slot_keys)
      |> assign(:storage_inventory, storage_inventory)
      |> assign(:catalog, catalog)
      |> assign(:inbox_display, inbox_display)
      |> assign(:pending_deliveries, pending_deliveries)
      |> assign(:recent_sales_display, recent_sales_display)
      |> assign(:physical_worker_last_report, physical_worker_last_report)
      |> assign(:physical_worker_run_count, physical_worker_run_count)
      |> assign(:weather, weather)
      |> assign(:season, season)
      |> assign(:weather_kind, weather_kind)
      |> assign(:season_name, season_name)

    ~H"""
    <div class="relative w-full font-sans" style="background: #0a0f0d; color: #e8f0ea; min-height: 640px;">
      <style>
        /* ── Ticker Pulse ── */
        @keyframes vb-ticker-pulse {
          0%, 100% { opacity: 0.7; }
          50% { opacity: 1; }
        }
        .vb-active { animation: vb-ticker-pulse 2.5s ease-in-out infinite; }

        /* ── Sale Flash ── */
        @keyframes vb-sale-flash {
          from { background: rgba(16,185,129,0.25); }
          to { background: transparent; }
        }
        .vb-sale-item { animation: vb-sale-flash 1.2s ease-out forwards; }

        /* ── Slot Glow ── */
        @keyframes vb-slot-glow {
          0%, 100% { box-shadow: 0 0 0 0 rgba(16,185,129,0); }
          50% { box-shadow: 0 0 8px 2px rgba(16,185,129,0.25); }
        }
        .vb-slot-active { animation: vb-slot-glow 2s ease-in-out infinite; }

        /* ── Scanline ── */
        @keyframes vb-scanline {
          0% { transform: translateY(-100%); }
          100% { transform: translateY(100%); }
        }
        .vb-scanline::after {
          content: '';
          position: absolute;
          top: 0; left: 0; right: 0;
          height: 2px;
          background: linear-gradient(90deg, transparent, rgba(16,185,129,0.10), transparent);
          animation: vb-scanline 6s linear infinite;
          pointer-events: none;
        }
      </style>

      <!-- Status Bar -->
      <div style="background: #0f1a14; border-bottom: 1px solid #1a3024; padding: 10px 20px; display: flex; align-items: center; justify-content: space-between; gap: 16px; flex-wrap: wrap;">
        <div style="display: flex; align-items: center; gap: 14px;">
          <span style="font-size: 11px; letter-spacing: 3px; color: #10b981; font-weight: 700;">VENDING BENCH</span>
          <span style="color: #1a3024;">|</span>
          <span style="font-size: 12px; color: #6ee7b7; font-weight: 600;">
            Day <%= @day_number %>/<%= @max_days %> &nbsp; <%= @time_display %>
          </span>
          <%= if @season_name do %>
            <span style="font-size: 11px; color: #4a7c62; font-style: italic;"><%= humanize(to_string(@season_name)) %></span>
          <% end %>
          <%= if @weather_kind do %>
            <span style="font-size: 11px; color: #4a7c62;"><%= weather_icon(@weather_kind) %> <%= humanize(to_string(@weather_kind)) %></span>
          <% end %>
        </div>
        <div style="display: flex; align-items: center; gap: 12px;">
          <.money_pill label="BANK" value={@bank_balance} color="#10b981" />
          <.money_pill label="MACHINE" value={@cash_in_machine} color="#34d399" />
          <span class="vb-active" style={"padding: 3px 10px; border-radius: 12px; font-size: 10px; font-weight: 700; letter-spacing: 1px; background: #{phase_bg(@phase)}; color: #{phase_color(@phase)};"}>
            <%= phase_label(@phase) %>
          </span>
          <%= if @status == "complete" do %>
            <span style="padding: 3px 10px; border-radius: 12px; font-size: 10px; font-weight: 700; background: rgba(16,185,129,0.15); color: #10b981;">
              CONCLUDED
            </span>
          <% end %>
        </div>
      </div>

      <!-- Main Layout: left sidebar | center machine | right panels -->
      <div style="display: grid; grid-template-columns: 200px 1fr 240px; gap: 0; min-height: 560px;">

        <!-- Left: Storage + Financials + Worker -->
        <div style="border-right: 1px solid #1a3024; padding: 12px 0; display: flex; flex-direction: column; gap: 0;">

          <!-- Financials panel -->
          <div style="padding: 6px 12px 12px;">
            <div style="font-size: 10px; letter-spacing: 2px; color: #166534; font-weight: 700; margin-bottom: 8px; padding-top: 2px;">
              FINANCIALS
            </div>
            <div style="display: flex; flex-direction: column; gap: 5px;">
              <.stat_row label="Bank Balance" value={"$#{format_money(@bank_balance)}"} color="#10b981" />
              <.stat_row label="Cash in Machine" value={"$#{format_money(@cash_in_machine)}"} color="#34d399" />
              <.stat_row label="Daily Fee" value={"$#{format_money(@daily_fee)}"} color="#f87171" />
              <div style="height: 1px; background: #1a3024; margin: 4px 0;"></div>
              <.stat_row label="Net Liquid" value={"$#{format_money(@bank_balance + @cash_in_machine)}"} color="#6ee7b7" />
            </div>
          </div>

          <div style="height: 1px; background: #1a3024; margin: 0 12px 12px;"></div>

          <!-- Storage Inventory -->
          <div style="padding: 0 12px 12px; flex: 1;">
            <div style="font-size: 10px; letter-spacing: 2px; color: #166534; font-weight: 700; margin-bottom: 8px;">
              STORAGE
            </div>
            <%= if map_size(@storage_inventory) == 0 do %>
              <div style="font-size: 11px; color: #2d5940; font-style: italic;">Empty</div>
            <% else %>
              <div style="display: flex; flex-direction: column; gap: 3px; max-height: 200px; overflow-y: auto;">
                <%= for {item_id, qty} <- Enum.sort(@storage_inventory) do %>
                  <% item_name = get_item_name(@catalog, item_id) %>
                  <div style="display: flex; align-items: center; gap: 6px; padding: 4px 6px; border-radius: 4px; background: rgba(16,185,129,0.05);">
                    <span style="width: 6px; height: 6px; border-radius: 50%; background: #10b981; flex-shrink: 0;"></span>
                    <span style="font-size: 10px; color: #6ee7b7; flex: 1; font-family: monospace; overflow: hidden; text-overflow: ellipsis; white-space: nowrap;">
                      <%= item_name %>
                    </span>
                    <span style="font-size: 10px; font-weight: 700; color: #10b981; font-family: monospace;"><%= qty %></span>
                  </div>
                <% end %>
              </div>
            <% end %>
          </div>

          <div style="height: 1px; background: #1a3024; margin: 0 12px 12px;"></div>

          <!-- Worker Status -->
          <div style="padding: 0 12px 10px;">
            <div style="font-size: 10px; letter-spacing: 2px; color: #166534; font-weight: 700; margin-bottom: 8px;">
              WORKER
            </div>
            <div style="display: flex; align-items: center; gap: 6px; margin-bottom: 6px;">
              <span style={"width: 8px; height: 8px; border-radius: 50%; background: #{if @physical_worker_last_report, do: "#10b981", else: "#374151"}; flex-shrink: 0;"}></span>
              <span style="font-size: 10px; color: #6ee7b7;">
                Runs: <strong style="color: #10b981;"><%= @physical_worker_run_count %></strong>
              </span>
            </div>
            <%= if @physical_worker_last_report do %>
              <div style="font-size: 10px; color: #4a7c62; line-height: 1.5; font-style: italic; max-height: 80px; overflow-y: auto;">
                <%= truncate(get_val(@physical_worker_last_report, :summary, ""), 120) %>
              </div>
            <% else %>
              <div style="font-size: 10px; color: #2d5940; font-style: italic;">No report yet</div>
            <% end %>
          </div>

        </div>

        <!-- Center: Machine Slot Grid -->
        <div style="padding: 16px 20px; display: flex; flex-direction: column; gap: 16px;">

          <!-- Machine header -->
          <div style="display: flex; align-items: center; justify-content: space-between;">
            <div style="font-size: 10px; letter-spacing: 2px; color: #166534; font-weight: 700;">MACHINE SLOTS</div>
            <div style="font-size: 10px; color: #4a7c62;">4 rows x 3 cols</div>
          </div>

          <!-- Slot grid: rows A-D, cols 1-3 -->
          <div style="display: grid; grid-template-columns: repeat(3, 1fr); gap: 8px;">
            <%= for slot_key <- @slot_keys do %>
              <% slot = get_slot(@slots, slot_key) %>
              <% item_id = get_val(slot, :item_id, nil) %>
              <% inventory = get_val(slot, :inventory, 0) %>
              <% price = get_val(slot, :price, nil) %>
              <% slot_type = get_val(slot, :slot_type, "standard") %>
              <% item_name = if item_id, do: get_item_name(@catalog, item_id), else: nil %>
              <% is_empty = inventory == 0 %>
              <% is_vacant = item_id == nil %>
              <.slot_card
                slot_key={slot_key}
                item_name={item_name}
                item_id={item_id}
                inventory={inventory}
                price={price}
                slot_type={slot_type}
                is_empty={is_empty}
                is_vacant={is_vacant}
              />
            <% end %>
          </div>

          <!-- Recent Sales -->
          <div style="flex: 1; background: #0f1a14; border-radius: 8px; border: 1px solid #1a3024; overflow: hidden;">
            <div style="padding: 10px 14px; border-bottom: 1px solid #1a3024; font-size: 10px; letter-spacing: 2px; color: #166534; font-weight: 700; background: rgba(15,26,20,0.8);">
              RECENT SALES
            </div>
            <div style="padding: 6px 4px; max-height: 180px; overflow-y: auto;">
              <%= if @recent_sales_display == [] do %>
                <div style="text-align: center; padding: 24px 20px; font-size: 12px; color: #2d5940; font-style: italic;">
                  No sales recorded yet...
                </div>
              <% else %>
                <%= for sale <- @recent_sales_display do %>
                  <% sale_item = get_val(sale, :item_id, get_val(sale, :item, "?")) %>
                  <% sale_price = get_val(sale, :revenue, get_val(sale, :amount, 0)) %>
                  <% sale_slot = get_val(sale, :slot_id, get_val(sale, :slot_key, "")) %>
                  <% sale_time = get_val(sale, :day, nil) %>
                  <% sale_name = get_item_name(@catalog, sale_item) %>
                  <div class="vb-sale-item" style="padding: 6px 14px; border-bottom: 1px solid #122318; display: flex; align-items: center; gap: 8px;">
                    <span style="font-size: 10px; font-weight: 700; color: #10b981; font-family: monospace; min-width: 28px;"><%= sale_slot %></span>
                    <span style="font-size: 11px; color: #6ee7b7; flex: 1; overflow: hidden; text-overflow: ellipsis; white-space: nowrap;"><%= sale_name %></span>
                    <span style="font-size: 11px; font-weight: 700; color: #34d399; font-family: monospace;">$<%= format_money(sale_price) %></span>
                    <%= if sale_time do %>
                      <span style="font-size: 9px; color: #2d5940; font-family: monospace;"><%= format_sale_time(sale_time) %></span>
                    <% end %>
                  </div>
                <% end %>
              <% end %>
            </div>
          </div>
        </div>

        <!-- Right: Inbox + Pending Deliveries -->
        <div style="border-left: 1px solid #1a3024; padding: 12px 0; display: flex; flex-direction: column; gap: 0;">

          <!-- Inbox -->
          <div style="padding: 6px 12px 12px;">
            <div style="font-size: 10px; letter-spacing: 2px; color: #166534; font-weight: 700; margin-bottom: 8px; padding-top: 2px;">
              INBOX
              <%= if length(@inbox_display) > 0 do %>
                <span style="margin-left: 6px; background: rgba(16,185,129,0.2); color: #10b981; border-radius: 10px; padding: 1px 7px; font-size: 10px;"><%= length(@inbox_display) %></span>
              <% end %>
            </div>
            <%= if @inbox_display == [] do %>
              <div style="font-size: 11px; color: #2d5940; font-style: italic; padding: 8px 0;">No messages</div>
            <% else %>
              <div style="display: flex; flex-direction: column; gap: 5px; max-height: 220px; overflow-y: auto;">
                <%= for msg <- @inbox_display do %>
                  <% msg_from = get_val(msg, :from, get_val(msg, :sender, "system")) %>
                  <% msg_subject = get_val(msg, :subject, get_val(msg, :type, "message")) %>
                  <% msg_body = get_val(msg, :body, get_val(msg, :content, get_val(msg, :message, ""))) %>
                  <div style="background: rgba(16,185,129,0.05); border: 1px solid #1a3024; border-radius: 6px; padding: 7px 10px;">
                    <div style="display: flex; align-items: center; gap: 6px; margin-bottom: 3px;">
                      <span style="width: 5px; height: 5px; border-radius: 50%; background: #10b981; flex-shrink: 0;"></span>
                      <span style="font-size: 10px; font-weight: 700; color: #10b981; font-family: monospace; overflow: hidden; text-overflow: ellipsis; white-space: nowrap;"><%= msg_from %></span>
                    </div>
                    <%= if msg_subject && msg_subject != "message" do %>
                      <div style="font-size: 10px; font-weight: 600; color: #6ee7b7; margin-bottom: 2px;"><%= truncate(to_string(msg_subject), 40) %></div>
                    <% end %>
                    <div style="font-size: 10px; color: #4a7c62; line-height: 1.4;">
                      <%= truncate(to_string(msg_body), 100) %>
                    </div>
                  </div>
                <% end %>
              </div>
            <% end %>
          </div>

          <div style="height: 1px; background: #1a3024; margin: 0 12px 12px;"></div>

          <!-- Pending Deliveries -->
          <div style="padding: 0 12px;">
            <div style="font-size: 10px; letter-spacing: 2px; color: #166534; font-weight: 700; margin-bottom: 8px;">
              PENDING DELIVERIES
            </div>
            <%= if @pending_deliveries == [] do %>
              <div style="font-size: 11px; color: #2d5940; font-style: italic; padding: 8px 0;">None</div>
            <% else %>
              <div style="display: flex; flex-direction: column; gap: 4px; max-height: 200px; overflow-y: auto;">
                <%= for delivery <- @pending_deliveries do %>
                  <% del_item = get_val(delivery, :item_id, get_val(delivery, :item, "?")) %>
                  <% del_qty = get_val(delivery, :quantity, get_val(delivery, :qty, 0)) %>
                  <% del_arrive = get_val(delivery, :delivery_day, get_val(delivery, :eta_day, nil)) %>
                  <% del_name = get_item_name(@catalog, del_item) %>
                  <div style="display: flex; align-items: center; gap: 6px; padding: 5px 8px; border-radius: 5px; background: rgba(16,185,129,0.05); border: 1px solid #1a3024;">
                    <span style="font-size: 10px; color: #6ee7b7; flex: 1; overflow: hidden; text-overflow: ellipsis; white-space: nowrap;"><%= del_name %></span>
                    <span style="font-size: 10px; font-weight: 700; color: #10b981; font-family: monospace;">x<%= del_qty %></span>
                    <%= if del_arrive do %>
                      <span style="font-size: 9px; color: #2d5940; font-family: monospace;">D<%= del_arrive %></span>
                    <% end %>
                  </div>
                <% end %>
              </div>
            <% end %>
          </div>

        </div>
      </div>
    </div>
    """
  end

  # -- Sub-components --

  attr(:label, :string, required: true)
  attr(:value, :any, required: true)
  attr(:color, :string, default: "#10b981")

  defp money_pill(assigns) do
    ~H"""
    <div style={"display: flex; align-items: center; gap: 5px; padding: 3px 10px; border-radius: 12px; background: #{@color}22; border: 1px solid #{@color}44;"}>
      <span style={"font-size: 9px; letter-spacing: 1px; color: #{@color}; font-weight: 700;"}><%= @label %></span>
      <span style={"font-size: 11px; font-weight: 700; color: #{@color}; font-family: monospace;"}>$<%= format_money(@value) %></span>
    </div>
    """
  end

  attr(:label, :string, required: true)
  attr(:value, :string, required: true)
  attr(:color, :string, default: "#6ee7b7")

  defp stat_row(assigns) do
    ~H"""
    <div style="display: flex; align-items: center; justify-content: space-between; gap: 6px;">
      <span style="font-size: 10px; color: #4a7c62;"><%= @label %></span>
      <span style={"font-size: 10px; font-weight: 700; color: #{@color}; font-family: monospace;"}><%= @value %></span>
    </div>
    """
  end

  attr(:slot_key, :string, required: true)
  attr(:item_name, :string, default: nil)
  attr(:item_id, :string, default: nil)
  attr(:inventory, :integer, default: 0)
  attr(:price, :any, default: nil)
  attr(:slot_type, :string, default: "standard")
  attr(:is_empty, :boolean, default: false)
  attr(:is_vacant, :boolean, default: true)

  defp slot_card(assigns) do
    ~H"""
    <div class={if !@is_vacant and !@is_empty, do: "vb-slot-active", else: ""}
         style={"padding: 8px 10px; border-radius: 7px; border: 1px solid #{slot_border_color(@is_vacant, @is_empty)}; background: #{slot_bg_color(@is_vacant, @is_empty)}; min-height: 72px; display: flex; flex-direction: column; gap: 4px;"}>
      <!-- Slot ID + type -->
      <div style="display: flex; align-items: center; justify-content: space-between;">
        <span style={"font-size: 12px; font-weight: 800; color: #{slot_key_color(@is_vacant, @is_empty)}; font-family: monospace; letter-spacing: 1px;"}><%= @slot_key %></span>
        <%= if @slot_type && @slot_type != "standard" do %>
          <span style="font-size: 8px; color: #2d5940; font-family: monospace; letter-spacing: 1px;"><%= String.upcase(to_string(@slot_type)) %></span>
        <% end %>
      </div>
      <!-- Item name -->
      <div style={"font-size: 10px; color: #{if @is_vacant, do: "#2d5940", else: "#6ee7b7"}; font-style: #{if @is_vacant, do: "italic", else: "normal"}; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; flex: 1;"}>
        <%= if @is_vacant do %>
          vacant
        <% else %>
          <%= @item_name || @item_id || "—" %>
        <% end %>
      </div>
      <!-- Inventory + price row -->
      <%= if !@is_vacant do %>
        <div style="display: flex; align-items: center; justify-content: space-between; gap: 4px;">
          <span style={"font-size: 10px; font-weight: 700; font-family: monospace; color: #{if @is_empty, do: "#f87171", else: "#10b981"};"}>
            <%= if @is_empty do %>OUT<% else %>x<%= @inventory %><% end %>
          </span>
          <%= if @price do %>
            <span style="font-size: 10px; font-weight: 700; color: #34d399; font-family: monospace;">$<%= format_money(@price) %></span>
          <% end %>
        </div>
      <% end %>
    </div>
    """
  end

  # -- Helpers --

  defp get_slot(slots, key) when is_map(slots) do
    Map.get(slots, key, Map.get(slots, String.to_atom(key), %{}))
  end

  defp get_slot(_slots, _key), do: %{}

  defp get_item_name(_catalog, nil), do: "—"

  defp get_item_name(catalog, item_id) when is_map(catalog) do
    item_id_str = to_string(item_id)
    item_id_atom = if is_atom(item_id), do: item_id, else: String.to_atom(item_id_str)

    info =
      Map.get(
        catalog,
        item_id_str,
        Map.get(catalog, item_id_atom, Map.get(catalog, item_id, nil))
      )

    case info do
      nil ->
        humanize(item_id_str)

      info when is_map(info) ->
        get_val(
          info,
          :display_name,
          get_val(info, :name, get_val(info, :label, humanize(item_id_str)))
        )

      other ->
        to_string(other)
    end
  end

  defp get_item_name(_catalog, item_id), do: humanize(to_string(item_id))

  defp humanize(str) do
    str
    |> String.replace("_", " ")
    |> String.split(" ")
    |> Enum.map(&String.capitalize/1)
    |> Enum.join(" ")
  end

  defp format_money(nil), do: "0.00"
  defp format_money(val) when is_float(val), do: :erlang.float_to_binary(val, decimals: 2)

  defp format_money(val) when is_integer(val) do
    dollars = div(val, 100)
    cents = rem(val, 100) |> abs()
    "#{dollars}.#{String.pad_leading(Integer.to_string(cents), 2, "0")}"
  end

  defp format_money(val) do
    case Float.parse(to_string(val)) do
      {f, _} -> :erlang.float_to_binary(f, decimals: 2)
      :error -> to_string(val)
    end
  end

  defp format_time(nil), do: "00:00"

  defp format_time(minutes) when is_integer(minutes) do
    h = div(minutes, 60) |> rem(24)
    m = rem(minutes, 60)

    "#{String.pad_leading(Integer.to_string(h), 2, "0")}:#{String.pad_leading(Integer.to_string(m), 2, "0")}"
  end

  defp format_time(_), do: "00:00"

  defp format_sale_time(t) when is_integer(t), do: "D#{t}"
  defp format_sale_time(t), do: to_string(t)

  defp truncate(nil, _), do: ""

  defp truncate(str, max) when is_binary(str) do
    if String.length(str) > max do
      String.slice(str, 0, max) <> "..."
    else
      str
    end
  end

  defp truncate(val, max), do: truncate(to_string(val), max)

  defp slot_border_color(true, _), do: "#1a3024"
  defp slot_border_color(false, true), do: "rgba(248,113,113,0.3)"
  defp slot_border_color(false, false), do: "rgba(16,185,129,0.3)"

  defp slot_bg_color(true, _), do: "rgba(15,26,20,0.5)"
  defp slot_bg_color(false, true), do: "rgba(248,113,113,0.05)"
  defp slot_bg_color(false, false), do: "rgba(16,185,129,0.06)"

  defp slot_key_color(true, _), do: "#2d5940"
  defp slot_key_color(false, true), do: "#f87171"
  defp slot_key_color(false, false), do: "#10b981"

  defp phase_label("setup"), do: "SETUP"
  defp phase_label("operating"), do: "OPERATING"
  defp phase_label("restocking"), do: "RESTOCKING"
  defp phase_label("maintenance"), do: "MAINTENANCE"
  defp phase_label("closed"), do: "CLOSED"
  defp phase_label("end_of_day"), do: "END OF DAY"
  defp phase_label(other), do: String.upcase(to_string(other || ""))

  defp phase_color("setup"), do: "#60a5fa"
  defp phase_color("operating"), do: "#10b981"
  defp phase_color("restocking"), do: "#fbbf24"
  defp phase_color("maintenance"), do: "#f87171"
  defp phase_color("closed"), do: "#6b7280"
  defp phase_color("end_of_day"), do: "#a78bfa"
  defp phase_color(_), do: "#4a7c62"

  defp phase_bg(phase) do
    color = phase_color(phase)
    "#{color}22"
  end

  defp weather_icon("mild"), do: "~"
  defp weather_icon("hot"), do: "☀"
  defp weather_icon("cold"), do: "❄"
  defp weather_icon("sunny"), do: "☀"
  defp weather_icon("rainy"), do: "🌧"
  defp weather_icon("stormy"), do: "⛈"
  defp weather_icon(_), do: "~"

  defp get_val(map, key, default) when is_map(map) and is_atom(key) do
    Map.get(map, key, Map.get(map, Atom.to_string(key), default))
  end

  defp get_val(_map, _key, default), do: default
end
