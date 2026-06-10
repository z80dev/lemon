defmodule LemonSimUi.Live.Components.VendingBenchBoard do
  use Phoenix.Component

  alias LemonCore.MapHelpers

  attr(:world, :map, required: true)
  attr(:interactive, :boolean, default: false)

  def render(assigns) do
    world = assigns.world
    arena_agents = MapHelpers.get_key(world, :arena_agents) || []
    arena_messages = MapHelpers.get_key(world, :arena_messages) || []
    arena_trades = MapHelpers.get_key(world, :arena_trades) || []
    display_world = arena_display_world(world, arena_agents)
    performance = LemonSim.Examples.VendingBench.Performance.summarize(display_world)

    status = MapHelpers.get_key(world, :status) || "in_progress"
    phase = MapHelpers.get_key(display_world, :phase) || "operating"
    day_number = MapHelpers.get_key(world, :day_number) || 1
    time_minutes = MapHelpers.get_key(display_world, :time_minutes) || 0
    max_days = MapHelpers.get_key(world, :max_days) || 30
    bank_balance = MapHelpers.get_key(display_world, :bank_balance) || 0
    cash_in_machine = MapHelpers.get_key(display_world, :cash_in_machine) || 0
    daily_fee = MapHelpers.get_key(display_world, :daily_fee) || 0
    machine = MapHelpers.get_key(display_world, :machine) || %{}
    slots = MapHelpers.get_key(machine, :slots) || %{}
    storage = MapHelpers.get_key(display_world, :storage) || %{}
    storage_inventory = MapHelpers.get_key(storage, :inventory) || %{}
    storage_capacity = MapHelpers.get_key(storage, :capacity_units) || 160
    storage_used = Enum.reduce(storage_inventory, 0, fn {_item_id, qty}, acc -> acc + qty end)
    catalog = MapHelpers.get_key(display_world, :catalog) || %{}
    inbox = MapHelpers.get_key(display_world, :inbox) || []
    outbox = MapHelpers.get_key(display_world, :outbox) || []
    reminders = MapHelpers.get_key(display_world, :reminders) || []
    open_reminders = Enum.reject(reminders, &(get_val(&1, :status, "open") == "done"))
    pending_deliveries = MapHelpers.get_key(display_world, :pending_deliveries) || []
    recent_sales = MapHelpers.get_key(display_world, :recent_sales) || []
    customer_complaints = MapHelpers.get_key(display_world, :customer_complaints) || []
    supplier_incidents = MapHelpers.get_key(display_world, :supplier_incident_history) || []
    physical_worker_last_report = MapHelpers.get_key(display_world, :physical_worker_last_report)
    physical_worker_run_count = MapHelpers.get_key(display_world, :physical_worker_run_count) || 0
    machine_fault_reports = MapHelpers.get_key(display_world, :machine_fault_reports) || []
    weather = MapHelpers.get_key(display_world, :weather)
    season = MapHelpers.get_key(display_world, :season)
    weather_kind = get_val(weather, :kind, nil)
    season_name = get_val(season, :name, nil)
    runtime_models = MapHelpers.get_key(world, :runtime_models) || %{}
    operator_model_label = runtime_model_label(runtime_models, :operator, world, :operator_model)

    physical_worker_model_label =
      runtime_model_label(runtime_models, :physical_worker, world, :physical_worker_model)

    progress_percent = progress_percent(day_number, max_days)
    top_product = top_product_name(recent_sales, catalog)
    headline = broadcast_headline(performance, pending_deliveries, customer_complaints)
    story_beats = story_beats(world, display_world, performance, top_product)

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
      |> assign(:performance, performance)
      |> assign(:slots, slots)
      |> assign(:slot_keys, slot_keys)
      |> assign(:storage_inventory, storage_inventory)
      |> assign(:storage_capacity, storage_capacity)
      |> assign(:storage_used, storage_used)
      |> assign(:catalog, catalog)
      |> assign(:inbox_display, inbox_display)
      |> assign(:outbox_count, length(outbox))
      |> assign(:open_reminders, open_reminders)
      |> assign(:pending_deliveries, pending_deliveries)
      |> assign(:recent_sales_display, recent_sales_display)
      |> assign(:customer_complaints, customer_complaints)
      |> assign(:supplier_incidents, supplier_incidents)
      |> assign(:physical_worker_last_report, physical_worker_last_report)
      |> assign(:physical_worker_run_count, physical_worker_run_count)
      |> assign(:machine_fault_reports, machine_fault_reports)
      |> assign(:arena_agents, arena_agents)
      |> assign(:arena_messages, arena_messages)
      |> assign(:arena_trades, arena_trades)
      |> assign(:weather, weather)
      |> assign(:season, season)
      |> assign(:weather_kind, weather_kind)
      |> assign(:season_name, season_name)
      |> assign(:operator_model_label, operator_model_label)
      |> assign(:physical_worker_model_label, physical_worker_model_label)
      |> assign(:progress_percent, progress_percent)
      |> assign(:top_product, top_product)
      |> assign(:headline, headline)
      |> assign(:story_beats, story_beats)

    ~H"""
    <div class="relative w-full font-sans" style="background: #0a0f0d; color: #e8f0ea; min-height: 640px; max-width: 100%; overflow-x: hidden; box-sizing: border-box;">
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

        @keyframes vb-marquee {
          from { transform: translateX(0); }
          to { transform: translateX(-50%); }
        }
        .vb-marquee-track { animation: vb-marquee 26s linear infinite; }

        .vb-watch-grid {
          display: grid;
          grid-template-columns: minmax(0, 1fr) minmax(220px, 240px);
          gap: 16px;
          align-items: stretch;
          min-width: 0;
        }

        .vb-main-grid {
          display: grid;
          grid-template-columns: minmax(180px, 220px) minmax(320px, 1fr) minmax(220px, 260px);
          gap: 14px;
          min-height: 620px;
          min-width: 0;
          padding: 16px;
        }

        .vb-side-panel {
          border: 1px solid #1f3a2b;
          border-radius: 8px;
          background: linear-gradient(180deg, #111c16 0%, #0b120f 100%);
          box-shadow: inset 0 1px 0 rgba(255,255,255,0.04), 0 18px 40px rgba(0,0,0,0.28);
        }

        .vb-machine-shell {
          position: relative;
          min-height: 590px;
          border-radius: 18px;
          border: 4px solid #280b10;
          background:
            radial-gradient(circle at 18% 12%, rgba(255,255,255,0.16), transparent 12%),
            linear-gradient(135deg, #e64534 0%, #a51f2f 48%, #621424 100%);
          box-shadow: inset 0 0 0 3px rgba(255,255,255,0.08), inset -18px 0 34px rgba(0,0,0,0.22), 0 28px 60px rgba(0,0,0,0.42);
          padding: 18px;
          display: grid;
          grid-template-columns: minmax(0, 1fr) 112px;
          gap: 14px;
        }

        .vb-machine-marquee {
          grid-column: 1 / -1;
          min-height: 54px;
          border-radius: 10px;
          border: 3px solid #3b1017;
          background: linear-gradient(180deg, #ffe36d 0%, #f59e0b 100%);
          color: #3b1017;
          box-shadow: inset 0 2px 0 rgba(255,255,255,0.42), 0 6px 0 rgba(59,16,23,0.32);
          display: flex;
          align-items: center;
          justify-content: space-between;
          gap: 12px;
          padding: 10px 14px;
        }

        .vb-glass {
          position: relative;
          border-radius: 12px;
          border: 4px solid #1b2b31;
          background:
            linear-gradient(110deg, rgba(255,255,255,0.18) 0 6%, transparent 6% 45%, rgba(255,255,255,0.08) 45% 52%, transparent 52%),
            linear-gradient(180deg, #163139 0%, #071316 100%);
          box-shadow: inset 0 0 28px rgba(103,232,249,0.16), inset 0 0 0 2px rgba(255,255,255,0.05);
          padding: 12px;
          overflow: hidden;
        }

        .vb-slot-grid {
          display: grid;
          grid-template-columns: repeat(3, minmax(0, 1fr));
          gap: 10px;
          position: relative;
          z-index: 1;
        }

        .vb-control-panel {
          border-radius: 12px;
          border: 3px solid #321017;
          background: linear-gradient(180deg, #f5efe2 0%, #d8cbb7 100%);
          color: #2d1710;
          box-shadow: inset 0 2px 0 rgba(255,255,255,0.5), inset -8px 0 16px rgba(0,0,0,0.08);
          padding: 10px;
          display: flex;
          flex-direction: column;
          gap: 10px;
        }

        .vb-led {
          border-radius: 6px;
          border: 2px solid #142018;
          background: #07110b;
          color: #38f28f;
          font-family: monospace;
          font-size: 11px;
          line-height: 1.35;
          min-height: 58px;
          padding: 8px;
          text-shadow: 0 0 8px rgba(56,242,143,0.55);
        }

        .vb-keypad {
          display: grid;
          grid-template-columns: repeat(3, 1fr);
          gap: 6px;
        }

        .vb-key {
          aspect-ratio: 1;
          border-radius: 5px;
          border: 1px solid rgba(0,0,0,0.28);
          background: linear-gradient(180deg, #ffffff 0%, #c9c1b3 100%);
          color: #45241b;
          font-size: 11px;
          font-family: monospace;
          font-weight: 900;
          display: grid;
          place-items: center;
          box-shadow: 0 2px 0 rgba(0,0,0,0.28);
        }

        .vb-coin-slot,
        .vb-dispenser {
          border-radius: 7px;
          border: 2px solid #25130f;
          background: linear-gradient(180deg, #3c3a36 0%, #12100e 100%);
          box-shadow: inset 0 2px 8px rgba(0,0,0,0.55);
        }

        .vb-coin-slot { height: 26px; }

        .vb-dispenser {
          grid-column: 1 / -1;
          min-height: 70px;
          display: flex;
          align-items: center;
          justify-content: center;
          color: #fef3c7;
          font-size: 10px;
          font-weight: 900;
          letter-spacing: 2px;
        }

        @media (max-width: 900px) {
          .vb-watch-grid,
          .vb-main-grid {
            grid-template-columns: minmax(0, 1fr);
            padding: 12px;
          }

          .vb-machine-shell {
            grid-template-columns: minmax(0, 1fr);
            min-height: auto;
            padding: 12px;
          }

          .vb-control-panel {
            display: flex;
            flex-direction: column;
          }

          .vb-keypad {
            grid-template-columns: repeat(3, minmax(0, 1fr));
          }
        }
      </style>

      <!-- Status Bar -->
      <div style="background: #0f1a14; border-bottom: 1px solid #1a3024; padding: 10px 20px; display: flex; align-items: center; justify-content: space-between; gap: 16px; flex-wrap: wrap; box-sizing: border-box;">
        <div style="display: flex; align-items: center; gap: 14px; min-width: 0; flex-wrap: wrap;">
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
          <%= if @operator_model_label do %>
            <span style="font-size: 10px; color: #9fcfb8; border: 1px solid #1f3a2b; border-radius: 999px; padding: 3px 8px; background: #0b1711;">
              OP <span style="font-family: monospace; color: #e8f0ea;"><%= @operator_model_label %></span>
            </span>
          <% end %>
          <%= if @physical_worker_model_label do %>
            <span style="font-size: 10px; color: #9fcfb8; border: 1px solid #1f3a2b; border-radius: 999px; padding: 3px 8px; background: #0b1711;">
              WORKER <span style="font-family: monospace; color: #e8f0ea;"><%= @physical_worker_model_label %></span>
            </span>
          <% end %>
        </div>
        <div style="display: flex; align-items: center; gap: 12px; min-width: 0; flex-wrap: wrap;">
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

      <!-- Watch Mode Strip -->
      <div style="padding: 14px 20px 12px; border-bottom: 1px solid #1a3024; background: #0c1511; box-sizing: border-box;">
        <div class="vb-watch-grid">
          <div style="border: 1px solid #1f3a2b; border-radius: 8px; background: #0f1a14; overflow: hidden;">
            <div style="display: flex; align-items: center; justify-content: space-between; gap: 12px; padding: 10px 12px; border-bottom: 1px solid #1a3024;">
              <div>
                <div style="font-size: 10px; letter-spacing: 2px; color: #34d399; font-weight: 800;">VENDBENCH LIVE</div>
                <div style="font-size: 16px; line-height: 1.25; color: #e8f0ea; font-weight: 800; margin-top: 3px;"><%= @headline %></div>
              </div>
              <div style="min-width: 72px; text-align: right;">
                <div style="font-size: 10px; color: #80a894;">RUN</div>
                <div style="font-size: 20px; font-family: monospace; color: #fbbf24; font-weight: 900;"><%= @progress_percent %>%</div>
              </div>
            </div>
            <div style="height: 7px; background: #13251b;">
              <div style={"height: 7px; width: #{@progress_percent}%; background: #34d399; box-shadow: 0 0 10px rgba(52,211,153,0.35);"}></div>
            </div>
            <div style="overflow: hidden; border-top: 1px solid #13251b;">
              <div class="vb-marquee-track" style="display: flex; width: max-content; gap: 28px; padding: 8px 0; color: #80a894; font-size: 11px; white-space: nowrap;">
                <%= for beat <- @story_beats ++ @story_beats do %>
                  <span style="display: inline-flex; align-items: center; gap: 8px;">
                    <span style="width: 5px; height: 5px; border-radius: 50%; background: #fbbf24;"></span>
                    <%= beat %>
                  </span>
                <% end %>
              </div>
            </div>
          </div>

          <div style="display: grid; grid-template-columns: 1fr 1fr; gap: 8px;">
            <.broadcast_metric label="Top Seller" value={@top_product} color="#60a5fa" />
            <.broadcast_metric label="Run Rate" value={"#{@performance.units_sold} sold"} color="#34d399" />
            <.broadcast_metric label="Refund Heat" value={"$#{format_money(@performance.refunds_paid)}"} color="#fbbf24" />
            <.broadcast_metric label="Risk Flags" value={Integer.to_string(@performance.active_failure_mode_count)} color="#f87171" />
          </div>
        </div>
      </div>

      <%= if @arena_agents != [] do %>
        <div style="padding: 12px 20px; border-bottom: 1px solid #1a3024; background: #10110c;">
          <div style="display: flex; align-items: center; justify-content: space-between; gap: 12px; margin-bottom: 10px; flex-wrap: wrap;">
            <div style="font-size: 10px; letter-spacing: 2px; color: #fbbf24; font-weight: 900;">ARENA STANDINGS</div>
            <div style="font-size: 10px; color: #bfa76a;">Same location · individual scoring · price pressure active · <%= length(@arena_messages) %> messages · <%= length(@arena_trades) %> trades</div>
          </div>
          <div style="display: grid; grid-template-columns: repeat(auto-fit, minmax(180px, 1fr)); gap: 8px;">
            <%= for {agent, rank} <- Enum.with_index(@arena_agents, 1) do %>
              <div style="border: 1px solid rgba(251,191,36,0.25); border-radius: 8px; background: rgba(251,191,36,0.06); padding: 10px 12px;">
                <div style="display: flex; align-items: center; justify-content: space-between; gap: 8px; margin-bottom: 6px;">
                  <span style="font-size: 10px; color: #fbbf24; font-weight: 900;">#<%= rank %></span>
                  <span style="font-size: 10px; color: #bfa76a; font-family: monospace;"><%= get_val(agent, :id, "?") %></span>
                </div>
                <div style="font-size: 13px; color: #e8f0ea; font-weight: 800; overflow: hidden; text-overflow: ellipsis; white-space: nowrap;"><%= get_val(agent, :name, "Agent") %></div>
                <div style="display: flex; align-items: baseline; justify-content: space-between; gap: 8px; margin-top: 7px;">
                  <span style="font-size: 18px; color: #34d399; font-family: monospace; font-weight: 900;">$<%= format_money(get_val(agent, :money_balance, 0)) %></span>
                  <span style="font-size: 10px; color: #80a894;"><%= get_val(agent, :units_sold, 0) %> sold</span>
                </div>
              </div>
            <% end %>
          </div>
        </div>
      <% end %>

      <!-- Main Layout: left sidebar | center machine | right panels -->
      <div class="vb-main-grid">

        <!-- Left: Storage + Financials + Worker -->
        <div class="vb-side-panel" style="padding: 12px 0; display: flex; flex-direction: column; gap: 0; min-width: 0;">

          <!-- Financials panel -->
          <div style="padding: 6px 12px 12px;">
            <div style="font-size: 10px; letter-spacing: 2px; color: #166534; font-weight: 700; margin-bottom: 8px; padding-top: 2px;">
              FINANCIALS
            </div>
            <div style="display: flex; flex-direction: column; gap: 5px;">
              <.stat_row label="Bank Balance" value={"$#{format_money(@bank_balance)}"} color="#10b981" />
              <.stat_row label="Cash in Machine" value={"$#{format_money(@cash_in_machine)}"} color="#34d399" />
              <.stat_row label="Daily Fee" value={"$#{format_money(@daily_fee)}"} color="#f87171" />
              <.stat_row label="Refunds Paid" value={"$#{format_money(@performance.refunds_paid)}"} color="#fbbf24" />
              <.stat_row label="Spoilage Loss" value={"$#{format_money(@performance.spoilage_loss)}"} color="#fbbf24" />
              <div style="height: 1px; background: #1a3024; margin: 4px 0;"></div>
              <.stat_row label="Net Liquid" value={"$#{format_money(@bank_balance + @cash_in_machine)}"} color="#6ee7b7" />
              <.stat_row label="Money Balance" value={"$#{format_money(@performance.score_modes.money_balance)}"} color="#6ee7b7" />
            </div>
          </div>

          <div style="height: 1px; background: #1a3024; margin: 0 12px 12px;"></div>

          <!-- Storage Inventory -->
          <div style="padding: 0 12px 12px; flex: 1;">
            <div style="font-size: 10px; letter-spacing: 2px; color: #166534; font-weight: 700; margin-bottom: 8px;">
              STORAGE <span style="color: #4a7c62; letter-spacing: 0; font-family: monospace;">(<%= @storage_used %>/<%= @storage_capacity %>)</span>
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

        <!-- Center: Retro machine -->
        <div class="vb-machine-shell">
          <div class="vb-machine-marquee">
            <div style="min-width: 0;">
              <div style="font-size: 10px; letter-spacing: 2px; font-weight: 900;">LEMON VENDBOT</div>
              <div style="font-size: 20px; line-height: 1; font-weight: 900; overflow: hidden; text-overflow: ellipsis; white-space: nowrap;">
                <%= @headline %>
              </div>
            </div>
            <div style="text-align: right; font-family: monospace; font-weight: 900; font-size: 18px;">
              D<%= @day_number %>
            </div>
          </div>

          <div class="vb-glass vb-scanline">
            <div class="vb-slot-grid">
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
          </div>

          <div class="vb-control-panel">
            <div class="vb-led">
              <div style="font-size: 9px; color: #fbbf24; text-shadow: none; margin-bottom: 4px;">SELECT</div>
              <div><%= @top_product %></div>
              <div style="margin-top: 5px; color: #8ef7bb;">$<%= format_money(@cash_in_machine) %> inside</div>
            </div>
            <div class="vb-keypad">
              <%= for key <- ["A", "B", "C", "1", "2", "3"] do %>
                <div class="vb-key"><%= key %></div>
              <% end %>
            </div>
            <div>
              <div style="font-size: 9px; font-weight: 900; letter-spacing: 1px; margin-bottom: 5px;">COIN</div>
              <div class="vb-coin-slot"></div>
            </div>
            <div>
              <div style="font-size: 9px; font-weight: 900; letter-spacing: 1px; margin-bottom: 5px;">STATUS</div>
              <div style="border-radius: 6px; background: #2f1712; color: #fde68a; min-height: 42px; padding: 8px; font-size: 10px; font-family: monospace;">
                <%= phase_label(@phase) %><br />RUN <%= @progress_percent %>%
              </div>
            </div>
          </div>

          <div class="vb-dispenser">
            PRODUCT PICKUP
          </div>

          <div style="grid-column: 1 / -1; background: #0f1a14; border-radius: 8px; border: 1px solid #1a3024; overflow: hidden;">
            <div style="padding: 10px 14px; border-bottom: 1px solid #1a3024; font-size: 10px; letter-spacing: 2px; color: #34d399; font-weight: 800; background: rgba(15,26,20,0.8);">
              RECENT SALES
            </div>
            <div style="padding: 6px 4px; max-height: 132px; overflow-y: auto;">
              <%= if @recent_sales_display == [] do %>
                <div style="text-align: center; padding: 18px 20px; font-size: 12px; color: #2d5940; font-style: italic;">
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

        <!-- Right: Inbox + Pending Deliveries + Signals -->
        <div class="vb-side-panel" style="padding: 12px 0; display: flex; flex-direction: column; gap: 0; min-width: 0;">

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
                  <% ordered_item = get_val(delivery, :ordered_item_id, del_item) %>
                  <% delay_days = get_val(delivery, :delivery_delay_days, 0) %>
                  <% substituted_item = get_val(delivery, :substituted_item_id, nil) %>
                  <% del_qty = get_val(delivery, :quantity, get_val(delivery, :qty, 0)) %>
                  <% del_arrive = get_val(delivery, :delivery_day, get_val(delivery, :eta_day, nil)) %>
                  <% del_name = get_item_name(@catalog, del_item) %>
                  <div style="display: flex; flex-direction: column; gap: 3px; padding: 5px 8px; border-radius: 5px; background: rgba(16,185,129,0.05); border: 1px solid #1a3024;">
                    <div style="display: flex; align-items: center; gap: 6px;">
                      <span style="font-size: 10px; color: #6ee7b7; flex: 1; overflow: hidden; text-overflow: ellipsis; white-space: nowrap;"><%= del_name %></span>
                      <span style="font-size: 10px; font-weight: 700; color: #10b981; font-family: monospace;">x<%= del_qty %></span>
                      <%= if del_arrive do %>
                        <span style="font-size: 9px; color: #2d5940; font-family: monospace;">D<%= del_arrive %></span>
                      <% end %>
                    </div>
                    <%= if substituted_item || delay_days > 0 || ordered_item != del_item do %>
                      <div style="font-size: 9px; color: #fbbf24; line-height: 1.35;">
                        <%= delivery_note(ordered_item, del_item, substituted_item, delay_days) %>
                      </div>
                    <% end %>
                  </div>
                <% end %>
              </div>
            <% end %>
          </div>

          <div style="height: 1px; background: #1a3024; margin: 12px 12px;"></div>

          <!-- Operational Signals -->
          <div style="padding: 0 12px 10px;">
            <div style="font-size: 10px; letter-spacing: 2px; color: #166534; font-weight: 700; margin-bottom: 8px;">
              SCORECARD SIGNALS
            </div>
            <div style="display: flex; flex-direction: column; gap: 5px;">
              <.stat_row label="Outbox Sent" value={Integer.to_string(@outbox_count)} color="#6ee7b7" />
              <.stat_row label="Supplier Issues" value={Integer.to_string(length(@supplier_incidents))} color="#fbbf24" />
              <.stat_row label="Customer Complaints" value={Integer.to_string(length(@customer_complaints))} color="#fbbf24" />
              <.stat_row label="Machine Faults" value={Integer.to_string(length(@machine_fault_reports))} color="#fbbf24" />
              <.stat_row label="Open Reminders" value={Integer.to_string(length(@open_reminders))} color="#6ee7b7" />
              <.stat_row label="Spoiled Units" value={Integer.to_string(@performance.spoiled_units)} color="#fbbf24" />
              <.stat_row label="Overflow Units" value={Integer.to_string(@performance.storage_overflow_units)} color="#fbbf24" />
              <.stat_row label="Failure Modes" value={Integer.to_string(@performance.active_failure_mode_count)} color="#f87171" />
              <.stat_row label="Operational Score" value={to_string(@performance.score_modes.lemon_operational_score)} color="#10b981" />
            </div>
            <%= if @customer_complaints != [] do %>
              <% latest = List.last(@customer_complaints) %>
              <div style="margin-top: 8px; padding: 7px 9px; border-radius: 6px; border: 1px solid rgba(251,191,36,0.25); background: rgba(251,191,36,0.06); font-size: 10px; color: #fbbf24; line-height: 1.4;">
                Latest complaint: <%= humanize(to_string(get_val(latest, :reason, "customer complaint"))) %> · $<%= format_money(get_val(latest, :amount, 0)) %>
              </div>
            <% end %>
            <%= if @open_reminders != [] do %>
              <% reminder = List.first(Enum.sort_by(@open_reminders, &get_val(&1, :day, 0))) %>
              <div style="margin-top: 8px; padding: 7px 9px; border-radius: 6px; border: 1px solid rgba(110,231,183,0.25); background: rgba(110,231,183,0.05); font-size: 10px; color: #6ee7b7; line-height: 1.4;">
                Reminder D<%= get_val(reminder, :day, "?") %>: <%= truncate(to_string(get_val(reminder, :text, "")), 78) %>
              </div>
            <% end %>
            <%= if @machine_fault_reports != [] do %>
              <% fault = List.last(@machine_fault_reports) %>
              <div style="margin-top: 8px; padding: 7px 9px; border-radius: 6px; border: 1px solid rgba(251,191,36,0.25); background: rgba(251,191,36,0.06); font-size: 10px; color: #fbbf24; line-height: 1.4;">
                Fault: <%= humanize(to_string(get_val(fault, :severity, "low"))) %> · <%= truncate(to_string(get_val(fault, :description, "")), 72) %>
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

  defp broadcast_metric(assigns) do
    ~H"""
    <div style={"border: 1px solid #{@color}33; border-radius: 8px; background: #{@color}0f; padding: 10px 11px; min-width: 0;"}>
      <div style={"font-size: 9px; letter-spacing: 1px; color: #{@color}; font-weight: 800; margin-bottom: 5px;"}><%= @label %></div>
      <div style="font-size: 13px; color: #e8f0ea; font-weight: 800; overflow: hidden; text-overflow: ellipsis; white-space: nowrap;"><%= @value %></div>
    </div>
    """
  end

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
    <div style="display: flex; align-items: center; justify-content: space-between; gap: 6px; min-width: 0;">
      <span style="font-size: 10px; color: #4a7c62; min-width: 0; overflow: hidden; text-overflow: ellipsis; white-space: nowrap;"><%= @label %></span>
      <span style={"font-size: 10px; font-weight: 700; color: #{@color}; font-family: monospace; flex-shrink: 0; max-width: 88px; overflow: hidden; text-overflow: ellipsis; white-space: nowrap;"}><%= @value %></span>
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
         style={"padding: 8px; border-radius: 8px; border: 1px solid #{slot_border_color(@is_vacant, @is_empty)}; background: #{slot_bg_color(@is_vacant, @is_empty)}; min-height: 128px; display: flex; flex-direction: column; gap: 5px; box-shadow: inset 0 0 18px rgba(0,0,0,0.32);"}>
      <!-- Slot ID + type -->
      <div style="display: flex; align-items: center; justify-content: space-between;">
        <span style={"font-size: 12px; font-weight: 800; color: #{slot_key_color(@is_vacant, @is_empty)}; font-family: monospace; letter-spacing: 1px;"}><%= @slot_key %></span>
        <%= if @slot_type && @slot_type != "standard" do %>
          <span style="font-size: 8px; color: #2d5940; font-family: monospace; letter-spacing: 1px;"><%= String.upcase(to_string(@slot_type)) %></span>
        <% end %>
      </div>
      <div style="height: 76px; border-radius: 6px; background: rgba(255,255,255,0.05); display: grid; place-items: center; overflow: hidden;">
        <%= if !@is_vacant do %>
          <div style={"width: #{product_sprite_width(@item_id)}; height: 76px; opacity: #{if @is_empty, do: "0.38", else: "1"}; background-image: url('/assets/vending_bench/products.png'); background-repeat: no-repeat; background-size: 500% 200%; background-position: #{product_sprite_position(@item_id)}; transform: scale(#{product_sprite_scale(@item_id)}); filter: drop-shadow(0 7px 8px rgba(0,0,0,0.34));"}></div>
        <% else %>
          <div style="width: 42%; height: 10px; border-radius: 999px; background: rgba(45,89,64,0.45);"></div>
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

  defp delivery_note(ordered_item, delivered_item, substituted_item, delay_days) do
    parts =
      if substituted_item || ordered_item != delivered_item do
        [
          "Substituted #{humanize(to_string(ordered_item))} -> #{humanize(to_string(delivered_item))}"
        ]
      else
        []
      end

    parts =
      if delay_days > 0 do
        parts ++ ["Delayed #{delay_days}d"]
      else
        parts
      end

    Enum.join(parts, " · ")
  end

  defp progress_percent(day_number, max_days) do
    day = max(to_int(day_number, 1), 1)
    max_days = max(to_int(max_days, 1), 1)

    day
    |> Kernel.*(100)
    |> div(max_days)
    |> min(100)
  end

  defp top_product_name([], _catalog), do: "No sales yet"

  defp top_product_name(recent_sales, catalog) do
    recent_sales
    |> Enum.group_by(&get_val(&1, :item_id, get_val(&1, :item, nil)))
    |> Enum.reject(fn {item_id, _sales} -> is_nil(item_id) end)
    |> Enum.map(fn {item_id, sales} ->
      quantity = Enum.reduce(sales, 0, &(get_val(&1, :quantity, 0) + &2))
      {item_id, quantity}
    end)
    |> Enum.sort_by(fn {_item_id, quantity} -> -quantity end)
    |> case do
      [{item_id, _quantity} | _] -> get_item_name(catalog, item_id)
      [] -> "No sales yet"
    end
  end

  defp broadcast_headline(performance, pending_deliveries, customer_complaints) do
    cond do
      performance.active_failure_mode_count > 0 ->
        "Operator under pressure with #{performance.active_failure_mode_count} risk flag(s)"

      customer_complaints != [] ->
        "Customer desk is active after refund pressure"

      pending_deliveries != [] ->
        "Supply chain watch: #{length(pending_deliveries)} delivery run(s) inbound"

      performance.units_sold > 0 ->
        "Machine is moving product and banking cash"

      true ->
        "Opening shift: strategy forming before the first sale"
    end
  end

  defp arena_display_world(world, []) do
    world
  end

  defp arena_display_world(world, [leader | _]) do
    case {MapHelpers.get_key(world, :machine), get_val(leader, :world, nil)} do
      {nil, leader_world} when is_map(leader_world) ->
        leader_world

      {%{} = machine, leader_world} when map_size(machine) == 0 and is_map(leader_world) ->
        leader_world

      _ ->
        world
    end
  end

  defp story_beats(world, display_world, performance, top_product) do
    [
      "Bank $#{format_money(get_val(display_world, :bank_balance, 0))}",
      "money balance $#{format_money(performance.score_modes.money_balance)}",
      "Top seller #{top_product}",
      "#{performance.units_sold} units sold",
      "#{performance.supplier_incident_count} supplier incident(s)",
      "#{performance.worker_trip_count} worker trip(s)"
    ]
    |> maybe_append_arena_beats(world)
  end

  defp maybe_append_arena_beats(beats, world) do
    agents = get_val(world, :arena_agents, [])

    if agents == [] do
      beats
    else
      beats ++
        [
          "#{length(agents)} agents competing",
          "#{length(get_val(world, :arena_messages, []))} arena message(s)",
          "#{length(get_val(world, :arena_trades, []))} arena trade(s)"
        ]
    end
  end

  defp runtime_model_label(runtime_models, role, world, fallback_key) do
    runtime_models
    |> get_val(role, nil)
    |> model_label()
    |> case do
      nil -> world |> get_val(fallback_key, nil) |> model_label()
      label -> label
    end
  end

  defp model_label(nil), do: nil

  defp model_label(model) when is_binary(model) do
    trimmed = String.trim(model)
    if trimmed == "", do: nil, else: trimmed
  end

  defp model_label(model) when is_atom(model), do: Atom.to_string(model)

  defp model_label(model) when is_map(model) do
    get_val(model, :label, nil) ||
      compact_model_label(
        get_val(model, :provider, nil),
        get_val(model, :id, get_val(model, :name, nil))
      )
  end

  defp model_label(model), do: model |> to_string() |> model_label()

  defp compact_model_label(provider, id) do
    provider = model_label(provider)
    id = model_label(id)

    cond do
      id in [nil, ""] -> provider
      provider in [nil, ""] -> id
      String.starts_with?(id, provider <> ":") -> id
      true -> provider <> ":" <> id
    end
  end

  defp to_int(value, _default) when is_integer(value), do: value
  defp to_int(value, _default) when is_float(value), do: trunc(value)

  defp to_int(value, default) do
    case Integer.parse(to_string(value)) do
      {int, _} -> int
      :error -> default
    end
  end

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

  defp product_sprite_position("sparkling_water"), do: "0% 0%"
  defp product_sprite_position("energy_drink"), do: "25% 0%"
  defp product_sprite_position("chips"), do: "50% 0%"
  defp product_sprite_position("candy_bar"), do: "75% 0%"
  defp product_sprite_position("cola"), do: "100% 0%"
  defp product_sprite_position("water"), do: "0% 100%"
  defp product_sprite_position("trail_mix"), do: "25% 100%"
  defp product_sprite_position("granola_bar"), do: "50% 100%"
  defp product_sprite_position("sandwich"), do: "75% 100%"
  defp product_sprite_position("protein_box"), do: "100% 100%"
  defp product_sprite_position(_), do: "50% 0%"

  defp product_sprite_width(item_id)
       when item_id in ["chips", "trail_mix", "sandwich", "protein_box"],
       do: "64px"

  defp product_sprite_width(item_id) when item_id in ["candy_bar", "granola_bar"], do: "48px"
  defp product_sprite_width(_), do: "46px"

  defp product_sprite_scale(item_id) when item_id in ["sparkling_water", "water"], do: "1.12"
  defp product_sprite_scale(item_id) when item_id in ["energy_drink", "cola"], do: "1.06"
  defp product_sprite_scale(_), do: "1"

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
