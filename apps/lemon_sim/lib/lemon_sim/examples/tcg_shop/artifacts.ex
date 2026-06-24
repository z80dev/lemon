defmodule LemonSim.Examples.TcgShop.Artifacts do
  @moduledoc false

  alias LemonSim.Bench.Artifacts.AtomicFile
  alias LemonSim.Examples.TcgShop.{ActionSpace, Performance}

  @default_artifact_root "apps/lemon_sim/priv/game_logs/tcg_shop"
  @sim_version "1.0.0"
  @deterministic_artifact_timestamp "1970-01-01T00:00:00Z"

  def write_run_artifacts(state, events, actions, opts) do
    artifact_dir =
      Keyword.get(opts, :artifact_dir) || Path.join(@default_artifact_root, state.sim_id)

    File.mkdir_p!(artifact_dir)

    scorecard =
      state.world
      |> Performance.scorecard()
      |> Map.put(:sim_id, state.sim_id)
      |> Map.put(:status, get(state.world, :status))
      |> Map.put(:day_number, get(state.world, :day_number))

    paths = %{
      final_world: Path.join(artifact_dir, "final_world.json"),
      events: Path.join(artifact_dir, "events.jsonl"),
      actions: Path.join(artifact_dir, "actions.jsonl"),
      scorecard: Path.join(artifact_dir, "scorecard.json"),
      config: Path.join(artifact_dir, "config.json"),
      commands: Path.join(artifact_dir, "commands.jsonl"),
      facts: Path.join(artifact_dir, "facts.jsonl"),
      market: Path.join(artifact_dir, "market.json"),
      inventory: Path.join(artifact_dir, "inventory.json"),
      counterparty_transcript: Path.join(artifact_dir, "counterparty_transcript.json"),
      replay_json: Path.join(artifact_dir, "replay.json"),
      replay_html: Path.join(artifact_dir, "replay.html"),
      report: Path.join(artifact_dir, "report.md"),
      hashes: Path.join(artifact_dir, "hashes.json"),
      manifest: Path.join(artifact_dir, "manifest.json")
    }

    tool_schemas = tool_schema_artifact(state, opts)
    prompt = get(state.intent, :goal, "")

    replay = replay_artifact(state, events, actions, scorecard)

    contents = %{
      paths.final_world => Jason.encode!(jsonable(state.world), pretty: true),
      paths.events => jsonl(events),
      paths.actions => jsonl(actions),
      paths.commands => jsonl(Enum.filter(events, &command_event?/1)),
      paths.facts => jsonl(Enum.reject(events, &command_event?/1)),
      paths.scorecard => Jason.encode!(jsonable(scorecard), pretty: true),
      paths.config =>
        Jason.encode!(config_artifact(state, opts, tool_schemas, prompt), pretty: true),
      paths.market => Jason.encode!(market_artifact(state.world), pretty: true),
      paths.inventory => Jason.encode!(inventory_artifact(state.world), pretty: true),
      paths.counterparty_transcript =>
        Jason.encode!(counterparty_transcript_artifact(state.world), pretty: true),
      paths.replay_json => Jason.encode!(jsonable(replay), pretty: true),
      paths.replay_html => replay_html(replay),
      paths.report => report(state, scorecard, paths, opts)
    }

    Enum.each(contents, fn {path, content} -> AtomicFile.write!(path, content) end)

    hashes = hashes_artifact(artifact_dir, contents, prompt, tool_schemas)
    AtomicFile.write!(paths.hashes, Jason.encode!(hashes, pretty: true))

    AtomicFile.write!(
      paths.manifest,
      Jason.encode!(manifest_artifact(state, hashes, opts), pretty: true)
    )

    {:ok, paths}
  end

  defp command_event?(event) do
    event_kind(event) in [
      "tcg_order_product_line",
      "tcg_buy_collection",
      "tcg_open_sealed_product",
      "tcg_prepare_loose_packs",
      "tcg_take_consignment",
      "tcg_sell_memberships",
      "tcg_schedule_staff_shift",
      "tcg_upgrade_loss_prevention",
      "tcg_manage_credit_line",
      "tcg_make_bank_deposit",
      "tcg_file_supplier_claim",
      "tcg_set_prices",
      "tcg_host_event",
      "tcg_take_preorders",
      "tcg_take_special_order",
      "tcg_run_promotion",
      "tcg_manage_online_channel",
      "tcg_submit_grading",
      "tcg_process_customer_return",
      "tcg_process_online_orders",
      "tcg_wait_next_day"
    ]
  end

  defp event_kind(%{kind: kind}), do: kind
  defp event_kind(%{"kind" => kind}), do: kind
  defp event_kind(_event), do: nil

  defp config_artifact(state, opts, tool_schemas, prompt) do
    model = Keyword.get(opts, :model)

    %{
      schema_version: "lemon_sim.config.v1",
      sim_id: state.sim_id,
      seed: get(state.world, :seed),
      max_days: get(state.world, :max_days),
      driver_max_turns: Keyword.get(opts, :driver_max_turns),
      decision_max_turns: Keyword.get(opts, :decision_max_turns),
      offline_strategy: Keyword.get(opts, :offline_strategy),
      model: model_artifact(model),
      prompt_sha256: sha256(prompt),
      tool_schema_sha256: tool_schemas |> Jason.encode!() |> sha256()
    }
    |> jsonable()
  end

  defp model_artifact(nil), do: nil

  defp model_artifact(model) do
    %{
      provider: get(model, :provider),
      id: get(model, :id, get(model, :name)),
      name: get(model, :name)
    }
  end

  defp tool_schema_artifact(state, opts) do
    case ActionSpace.tools(state, opts) do
      {:ok, tools} ->
        tools
        |> Enum.map(fn tool ->
          %{name: tool.name, description: tool.description, parameters: tool.parameters}
        end)
        |> Enum.sort_by(& &1.name)

      _ ->
        []
    end
  end

  defp market_artifact(world) do
    %{
      market_pulses: get(world, :market_pulses, []),
      release_calendar: get(world, :release_calendar, []),
      research_history: get(world, :research_history, []),
      customer_base: get(world, :customer_base, %{}),
      customer_queue: get(world, :customer_queue, []),
      customer_history: get(world, :customer_history, []),
      store_credit_history: get(world, :store_credit_history, []),
      special_order_liability: get(world, :special_order_liability, 0.0),
      pending_special_orders: get(world, :pending_special_orders, []),
      special_order_history: get(world, :special_order_history, []),
      special_order_fulfillment_history: get(world, :special_order_fulfillment_history, []),
      sealed_opening_history: get(world, :sealed_opening_history, []),
      pack_inventory: get(world, :pack_inventory, %{}),
      pack_preparation_history: get(world, :pack_preparation_history, []),
      pack_sale_history: get(world, :pack_sale_history, []),
      consignment_lots: get(world, :consignment_lots, []),
      consignment_history: get(world, :consignment_history, []),
      consignment_sale_history: get(world, :consignment_sale_history, []),
      consignment_payout_history: get(world, :consignment_payout_history, []),
      active_memberships: get(world, :active_memberships, []),
      membership_history: get(world, :membership_history, []),
      tournament_history: get(world, :tournament_history, []),
      competitor_snapshot: get(world, :competitor_snapshot, %{}),
      competitive_position: get(world, :competitive_position, %{}),
      competitor_history: get(world, :competitor_history, []),
      active_promotions: get(world, :active_promotions, []),
      promotion_history: get(world, :promotion_history, []),
      online_channel: get(world, :online_channel, %{}),
      online_channel_history: get(world, :online_channel_history, []),
      supplier_accounts: get(world, :supplier_accounts, %{}),
      supplier_account_history: get(world, :supplier_account_history, []),
      pending_supplier_invoices: get(world, :pending_supplier_invoices, []),
      supplier_invoice_history: get(world, :supplier_invoice_history, []),
      delivery_receipt_history: get(world, :delivery_receipt_history, []),
      supplier_claim_history: get(world, :supplier_claim_history, []),
      stockout_history: get(world, :stockout_history, []),
      loss_prevention_score: get(world, :loss_prevention_score, 0),
      loss_prevention_history: get(world, :loss_prevention_history, []),
      stale_inventory_history: get(world, :stale_inventory_history, []),
      service_issue_history: get(world, :service_issue_history, []),
      refund_history: get(world, :refund_history, []),
      return_history: get(world, :return_history, []),
      operations: get(world, :operations, %{}),
      operations_history: get(world, :operations_history, []),
      staffing_history: get(world, :staffing_history, []),
      payroll_history: get(world, :payroll_history, []),
      overhead_history: get(world, :overhead_history, []),
      debt_history: get(world, :debt_history, []),
      cash_handling_history: get(world, :cash_handling_history, []),
      transaction_cost_history: get(world, :transaction_cost_history, []),
      tax_history: get(world, :tax_history, [])
    }
    |> jsonable()
  end

  defp inventory_artifact(world) do
    %{
      catalog: get(world, :catalog, %{}),
      inventory: get(world, :inventory, %{}),
      pack_inventory: get(world, :pack_inventory, %{}),
      singles_case: get(world, :singles_case, %{}),
      pending_deliveries: get(world, :pending_deliveries, []),
      pending_preorders: get(world, :pending_preorders, []),
      special_order_liability: get(world, :special_order_liability, 0.0),
      pending_special_orders: get(world, :pending_special_orders, []),
      pending_grading: get(world, :pending_grading, []),
      online_channel: get(world, :online_channel, %{}),
      online_channel_history: get(world, :online_channel_history, []),
      supplier_order_history: get(world, :supplier_order_history, []),
      supplier_accounts: get(world, :supplier_accounts, %{}),
      supplier_account_history: get(world, :supplier_account_history, []),
      debt_history: get(world, :debt_history, []),
      cash_handling_history: get(world, :cash_handling_history, []),
      store_credit_history: get(world, :store_credit_history, []),
      pending_supplier_invoices: get(world, :pending_supplier_invoices, []),
      supplier_invoice_history: get(world, :supplier_invoice_history, []),
      delivery_receipt_history: get(world, :delivery_receipt_history, []),
      supplier_claim_history: get(world, :supplier_claim_history, []),
      preorder_history: get(world, :preorder_history, []),
      preorder_fulfillment_history: get(world, :preorder_fulfillment_history, []),
      special_order_history: get(world, :special_order_history, []),
      special_order_fulfillment_history: get(world, :special_order_fulfillment_history, []),
      buylist_history: get(world, :buylist_history, []),
      sealed_opening_history: get(world, :sealed_opening_history, []),
      pack_preparation_history: get(world, :pack_preparation_history, []),
      pack_sale_history: get(world, :pack_sale_history, []),
      loss_prevention_score: get(world, :loss_prevention_score, 0),
      loss_prevention_history: get(world, :loss_prevention_history, []),
      consignment_lots: get(world, :consignment_lots, []),
      consignment_history: get(world, :consignment_history, []),
      consignment_sale_history: get(world, :consignment_sale_history, []),
      consignment_payout_history: get(world, :consignment_payout_history, []),
      active_memberships: get(world, :active_memberships, []),
      membership_history: get(world, :membership_history, []),
      staffing_history: get(world, :staffing_history, []),
      grading_history: get(world, :grading_history, []),
      grading_result_history: get(world, :grading_result_history, []),
      authentication_loss_history: get(world, :authentication_loss_history, []),
      singles_sale_history: get(world, :singles_sale_history, []),
      graded_sale_history: get(world, :graded_sale_history, []),
      return_history: get(world, :return_history, []),
      stale_inventory_history: get(world, :stale_inventory_history, []),
      shrinkage_history: get(world, :shrinkage_history, [])
    }
    |> jsonable()
  end

  defp counterparty_transcript_artifact(world) do
    %{
      schema_version: "tcg_shop.counterparties.v1",
      market_research: get(world, :research_history, []),
      suppliers: %{
        directory: get(world, :supplier_directory, []),
        accounts: get(world, :supplier_accounts, %{}),
        orders: get(world, :supplier_order_history, []),
        deliveries: get(world, :delivery_receipt_history, []),
        invoices: get(world, :supplier_invoice_history, []),
        claims: get(world, :supplier_claim_history, []),
        account_events: get(world, :supplier_account_history, [])
      },
      customers: %{
        base: get(world, :customer_base, %{}),
        queue: get(world, :customer_queue, []),
        updates: get(world, :customer_history, []),
        stockouts: get(world, :stockout_history, []),
        service_issues: get(world, :service_issue_history, []),
        returns: get(world, :return_history, []),
        refunds: get(world, :refund_history, []),
        preorders: get(world, :preorder_history, []),
        preorder_fulfillment: get(world, :preorder_fulfillment_history, []),
        special_orders: get(world, :special_order_history, []),
        special_order_fulfillment: get(world, :special_order_fulfillment_history, []),
        store_credit: get(world, :store_credit_history, [])
      },
      staff: %{
        scheduled_shifts: get(world, :staffing_history, []),
        operations: get(world, :operations_history, []),
        payroll: get(world, :payroll_history, [])
      },
      graders_and_consignors: %{
        submissions: get(world, :grading_history, []),
        results: get(world, :grading_result_history, []),
        authentication_losses: get(world, :authentication_loss_history, []),
        consignment_intake: get(world, :consignment_history, []),
        consignment_sales: get(world, :consignment_sale_history, []),
        consignment_payouts: get(world, :consignment_payout_history, [])
      }
    }
    |> jsonable()
  end

  defp replay_artifact(state, events, actions, scorecard) do
    %{
      schema_version: "tcg_shop.replay.v1",
      sim_id: state.sim_id,
      status: get(state.world, :status),
      scorecard: scorecard,
      beats: replay_beats(state.world, events),
      action_summaries: actions
    }
  end

  defp replay_beats(world, events) do
    day_events =
      events
      |> Enum.filter(&(event_kind(&1) == "tcg_day_advanced"))
      |> Enum.map(fn event ->
        %{
          day: get(event.payload, "day"),
          title: "Day #{get(event.payload, "day")} close",
          sales: get(event.payload, "sales", 0.0),
          market_pulse: get(event.payload, "market_pulse", %{})
        }
      end)

    business_events =
      (get(world, :tournament_history, []) ++
         get(world, :buylist_history, []) ++
         get(world, :membership_history, []) ++ get(world, :grading_history, []))
      |> Enum.map(fn entry ->
        %{
          day: get(entry, :day),
          title: replay_title(entry),
          detail: entry
        }
      end)

    (business_events ++ day_events)
    |> Enum.sort_by(&(get(&1, :day, 0) || 0))
  end

  defp replay_title(entry) do
    cond do
      get(entry, :game) ->
        "Hosted #{get(entry, :game)} event"

      get(entry, :type) == "sold" and get(entry, :member_count) ->
        "Sold #{get(entry, :franchise)} memberships"

      get(entry, :type) == "recognized" and get(entry, :member_count) ->
        "Recognized membership revenue"

      get(entry, :franchise) ->
        "Bought #{get(entry, :franchise)} collection"

      get(entry, :service_level) ->
        "Submitted grading order"

      true ->
        "Shop action"
    end
  end

  defp replay_html(replay) do
    beats =
      replay.beats
      |> Enum.map(fn beat ->
        "<li><strong>Day #{html(get(beat, :day, "?"))}</strong> #{html(get(beat, :title, ""))}</li>"
      end)
      |> Enum.join("\n")

    """
    <!doctype html>
    <html>
    <head>
      <meta charset="utf-8">
      <title>TCG Shop Replay #{html(replay.sim_id)}</title>
      <style>
        body { font-family: system-ui, sans-serif; background: #0f172a; color: #e2e8f0; margin: 2rem; }
        main { max-width: 900px; margin: 0 auto; }
        h1 { color: #fbbf24; }
        li { margin: .7rem 0; padding: .7rem; background: #1e293b; border: 1px solid #334155; border-radius: 8px; }
        code { color: #67e8f9; }
      </style>
    </head>
    <body>
      <main>
        <h1>TCG Shop Replay</h1>
        <p>Sim <code>#{html(replay.sim_id)}</code> finished with net worth $#{format_price(replay.scorecard.net_worth)}.</p>
        <ol>
          #{beats}
        </ol>
      </main>
    </body>
    </html>
    """
  end

  defp hashes_artifact(artifact_dir, contents, prompt, tool_schemas) do
    files =
      contents
      |> Enum.map(fn {path, content} ->
        {Path.relative_to(path, artifact_dir), sha256(content)}
      end)
      |> Map.new()

    %{
      schema_version: "lemon_sim.hashes.v1",
      files: files,
      prompt_sha256: sha256(prompt),
      tool_schema_sha256: tool_schemas |> Jason.encode!() |> sha256()
    }
  end

  defp manifest_artifact(state, hashes, opts) do
    now = artifact_timestamp(opts)

    %{
      schema_version: "lemon_sim.run.v1",
      sim: %{
        id: "tcg_shop",
        version: @sim_version,
        ruleset_hash: ruleset_hash(),
        seed: get(state.world, :seed)
      },
      agent: model_artifact(Keyword.get(opts, :model)),
      runtime: %{
        lemon_commit: git_commit(),
        elixir: System.version(),
        otp: :erlang.system_info(:otp_release) |> to_string(),
        started_at: Keyword.get(opts, :started_at, now),
        finished_at: Keyword.get(opts, :finished_at, now)
      },
      integrity: %{
        events_sha256: get_in(hashes, [:files, "events.jsonl"]),
        scorecard_sha256: get_in(hashes, [:files, "scorecard.json"]),
        prompt_sha256: hashes.prompt_sha256,
        tool_schema_sha256: hashes.tool_schema_sha256
      }
    }
    |> jsonable()
  end

  defp artifact_timestamp(opts) do
    cond do
      is_binary(Keyword.get(opts, :artifact_timestamp)) ->
        Keyword.fetch!(opts, :artifact_timestamp)

      Keyword.get(opts, :deterministic_artifacts?, false) ->
        @deterministic_artifact_timestamp

      true ->
        DateTime.utc_now() |> DateTime.to_iso8601()
    end
  end

  defp ruleset_hash do
    [
      "apps/lemon_sim/lib/lemon_sim/examples/tcg_shop.ex",
      "apps/lemon_sim/lib/lemon_sim/examples/tcg_shop/action_space.ex",
      "apps/lemon_sim/lib/lemon_sim/examples/tcg_shop/catalog.ex",
      "apps/lemon_sim/lib/lemon_sim/examples/tcg_shop/events.ex",
      "apps/lemon_sim/lib/lemon_sim/examples/tcg_shop/performance.ex",
      "apps/lemon_sim/lib/lemon_sim/examples/tcg_shop/updater.ex"
    ]
    |> Enum.map(fn path -> File.read!(path) end)
    |> Enum.join("\n")
    |> sha256()
  rescue
    _ -> nil
  end

  defp report(state, scorecard, paths, opts) do
    title = Keyword.get(opts, :artifact_report_title, "TCG Shop Run Report")

    """
    # #{title}

    Sim ID: #{state.sim_id}
    Status: #{get(state.world, :status)}
    Final day: #{get(state.world, :day_number)}

    ## Scores

    - Net worth: $#{format_price(scorecard.net_worth)}
    - Bank balance: $#{format_price(scorecard.bank_balance)}
    - Cash drawer balance: $#{format_price(scorecard.cash_drawer_balance)}
    - Cash tender sales: $#{format_price(scorecard.cash_tender_sales)}
    - Card tender sales: $#{format_price(scorecard.card_tender_sales)}
    - Bank deposits: $#{format_price(scorecard.bank_deposits)}
    - Cash reconciliations: #{scorecard.cash_reconciliations}
    - Cash over/short: $#{format_price(scorecard.cash_over_short)}
    - Cash shortage loss: $#{format_price(scorecard.cash_shortage_loss)}
    - Inventory value: $#{format_price(scorecard.inventory_value)}
    - Average inventory age: #{format_price(scorecard.average_inventory_age_days)} days
    - Stale inventory units: #{scorecard.stale_inventory_units}
    - Stale inventory markdown loss: $#{format_price(scorecard.stale_inventory_markdown_loss)}
    - Singles value: $#{format_price(scorecard.singles_value)}
    - Graded value: $#{format_price(scorecard.graded_value)}
    - Preorder liability: $#{format_price(scorecard.preorder_liability)}
    - Special order liability: $#{format_price(scorecard.special_order_liability)}
    - Sales tax liability: $#{format_price(scorecard.sales_tax_liability)}
    - Store credit liability: $#{format_price(scorecard.store_credit_liability)}
    - Consignment payable: $#{format_price(scorecard.consignment_payable)}
    - Membership liability: $#{format_price(scorecard.membership_liability)}
    - Credit line balance: $#{format_price(scorecard.credit_line_balance)}
    - Accounts payable: $#{format_price(scorecard.accounts_payable)}
    - ROI: #{format_price(scorecard.roi_pct)}%
    - Reputation: #{scorecard.reputation}
    - Online rating: #{scorecard.online_rating}

    ## Activity

    - Units/events sold: #{scorecard.sell_through_units}
    - Sales revenue: $#{format_price(scorecard.sales_revenue)}
    - Net sales revenue: $#{format_price(scorecard.net_sales_revenue)}
    - Cost of goods sold: $#{format_price(scorecard.cost_of_goods_sold)}
    - Gross profit: $#{format_price(scorecard.gross_profit)}
    - Gross margin: #{format_price(scorecard.gross_margin_pct)}%
    - Fixed overhead: $#{format_price(scorecard.fixed_overhead)}
    - Rent expense: $#{format_price(scorecard.rent_expense)}
    - Utilities expense: $#{format_price(scorecard.utilities_expense)}
    - Insurance expense: $#{format_price(scorecard.insurance_expense)}
    - Operating expenses: $#{format_price(scorecard.operating_expenses)}
    - Operating profit: $#{format_price(scorecard.operating_profit)}
    - Net profit after financing: $#{format_price(scorecard.net_profit_after_financing)}
    - Credit line draws: $#{format_price(scorecard.credit_line_draws)}
    - Credit line repayments: $#{format_price(scorecard.credit_line_repayments)}
    - Credit line interest: $#{format_price(scorecard.credit_line_interest)}
    - Refunds: $#{format_price(scorecard.refund_amount)}
    - Chargebacks: #{scorecard.chargeback_count}
    - Customer returns: #{scorecard.customer_returns}
    - Returned units: #{scorecard.returned_units}
    - Return refunds: $#{format_price(scorecard.return_refunds)}
    - Returned inventory units: #{scorecard.returned_inventory_units}
    - Return COGS recovered: $#{format_price(scorecard.return_cogs_recovered)}
    - Return writeoff loss: $#{format_price(scorecard.return_writeoff_loss)}
    - Raw singles sold: #{scorecard.raw_singles_sold}
    - Graded cards sold: #{scorecard.graded_cards_sold}
    - Preorder deposits: $#{format_price(scorecard.preorder_deposits)}
    - Preorder revenue: $#{format_price(scorecard.preorder_revenue)}
    - Preorder units fulfilled: #{scorecard.preorder_units_fulfilled}
    - Preorder units short: #{scorecard.preorder_units_short}
    - Pending preorder units: #{scorecard.pending_preorder_units}
    - Special order deposits: $#{format_price(scorecard.special_order_deposits)}
    - Special order revenue: $#{format_price(scorecard.special_order_revenue)}
    - Special order units fulfilled: #{scorecard.special_order_units_fulfilled}
    - Special order units short: #{scorecard.special_order_units_short}
    - Pending special order units: #{scorecard.pending_special_order_units}
    - Marketing spend: $#{format_price(scorecard.marketing_spend)}
    - Active promotions: #{scorecard.active_promotions}
    - Promoted units sold: #{scorecard.promoted_units_sold}
    - Promoted revenue: $#{format_price(scorecard.promoted_revenue)}
    - Taxable sales: $#{format_price(scorecard.taxable_sales)}
    - Sales tax collected: $#{format_price(scorecard.sales_tax_collected)}
    - Sales tax remitted: $#{format_price(scorecard.sales_tax_remitted)}
    - Payment processing fees: $#{format_price(scorecard.payment_processing_fees)}
    - Shipping label cost: $#{format_price(scorecard.shipping_label_cost)}
    - Marketplace fees: $#{format_price(scorecard.marketplace_fees)}
    - Online channel: #{scorecard.online_channel_platform} / #{scorecard.online_listing_quality}
    - Online channel updates: #{scorecard.online_channel_updates}
    - Online channel setup spend: $#{format_price(scorecard.online_channel_setup_spend)}
    - Packing supply cost: $#{format_price(scorecard.packing_supply_cost)}
    - Channel costs: $#{format_price(scorecard.channel_costs)}
    - Events hosted: #{scorecard.events_hosted}
    - Event attendance: #{scorecard.event_attendance}
    - Event capacity utilization: #{format_price(scorecard.event_capacity_utilization_pct)}%
    - Event turn-aways: #{scorecard.event_turn_aways}
    - Event no-shows: #{scorecard.event_no_shows}
    - Sanctioned events: #{scorecard.sanctioned_events}
    - Event prize value: $#{format_price(scorecard.event_prize_value)}
    - Event prize inventory cost: $#{format_price(scorecard.event_prize_inventory_cost)}
    - Event prize store credit: $#{format_price(scorecard.event_prize_store_credit)}
    - Event judge cost: $#{format_price(scorecard.event_judge_cost)}
    - Event sanction fees: $#{format_price(scorecard.event_sanction_fees)}
    - Event operating cost: $#{format_price(scorecard.event_operating_cost)}
    - Grading submissions: #{scorecard.grading_submissions}
    - Grading results: #{scorecard.grading_results}
    - Gem mint cards: #{scorecard.gem_mint_cards}
    - Mint cards: #{scorecard.mint_cards}
    - Authentication failures: #{scorecard.authenticated_failures}
    - Authentication loss: $#{format_price(scorecard.authentication_loss)}
    - Collection markdown loss: $#{format_price(scorecard.collection_markdown_loss)}
    - Sealed openings: #{scorecard.sealed_openings}
    - Sealed units opened: #{scorecard.sealed_units_opened}
    - Sealed packs opened: #{scorecard.sealed_packs_opened}
    - Sealed opening cards added: #{scorecard.sealed_opening_cards_added}
    - Sealed opening cost basis: $#{format_price(scorecard.sealed_opening_cost_basis)}
    - Sealed market value consumed: $#{format_price(scorecard.sealed_opening_market_value_consumed)}
    - Sealed opening singles value: $#{format_price(scorecard.sealed_opening_singles_value)}
    - Sealed opening value delta: $#{format_price(scorecard.sealed_opening_value_delta)}
    - Sealed opening chase hits: #{scorecard.sealed_opening_chase_hits}
    - Loose pack units: #{scorecard.loose_pack_units}
    - Loose pack inventory value: $#{format_price(scorecard.loose_pack_inventory_value)}
    - Loose pack preparations: #{scorecard.loose_pack_preparations}
    - Loose pack units prepared: #{scorecard.loose_pack_units_prepared}
    - Loose pack units sold: #{scorecard.loose_pack_units_sold}
    - Loose pack revenue: $#{format_price(scorecard.loose_pack_revenue)}
    - Loose pack gross profit: $#{format_price(scorecard.loose_pack_gross_profit)}
    - Consignment revenue: $#{format_price(scorecard.consignment_revenue)}
    - Consignment commission: $#{format_price(scorecard.consignment_commission)}
    - Consignment payable: $#{format_price(scorecard.consignment_payable)}
    - Consignment payouts paid: $#{format_price(scorecard.consignment_payouts_paid)}
    - Active memberships: #{scorecard.active_memberships}
    - Active membership batches: #{scorecard.active_membership_batches}
    - Membership revenue collected: $#{format_price(scorecard.membership_revenue_collected)}
    - Membership revenue recognized: $#{format_price(scorecard.membership_revenue_recognized)}
    - Store credit issued: $#{format_price(scorecard.store_credit_issued)}
    - Store credit redeemed: $#{format_price(scorecard.store_credit_redeemed)}
    - Supplier fill rate: #{format_price(scorecard.supplier_fill_rate_pct)}%
    - Allocation shortfalls: #{scorecard.allocation_shortfalls}
    - Supplier invoices open: #{scorecard.supplier_invoices_open}
    - Supplier invoices overdue: #{scorecard.supplier_invoices_overdue}
    - Supplier invoices paid: $#{format_price(scorecard.supplier_invoices_paid)}
    - Supplier late fees: $#{format_price(scorecard.supplier_late_fees)}
    - Average supplier standing: #{format_price(scorecard.average_supplier_standing)}
    - Preferred supplier accounts: #{scorecard.preferred_supplier_accounts}
    - Strained supplier accounts: #{scorecard.strained_supplier_accounts}
    - Supplier account events: #{scorecard.supplier_account_events}
    - Effective supplier credit limit: $#{format_price(scorecard.supplier_credit_limit_effective)}
    - Supplier credit available: $#{format_price(scorecard.supplier_credit_available)}
    - Damaged delivery units: #{scorecard.damaged_delivery_units}
    - Damaged delivery value: $#{format_price(scorecard.damaged_delivery_value)}
    - Supplier damage claims: #{scorecard.supplier_damage_claims}
    - Supplier claim credits: $#{format_price(scorecard.supplier_claim_credits)}
    - Staff hours used: #{format_price(scorecard.staff_hours_used)}
    - Scheduled staff shifts: #{scorecard.scheduled_staff_shifts}
    - Scheduled staff hours: #{format_price(scorecard.scheduled_staff_hours)}
    - Scheduled staff hours used: #{format_price(scorecard.scheduled_staff_hours_used)}
    - Scheduled staff cost: $#{format_price(scorecard.scheduled_staff_cost)}
    - Payroll paid hours: #{format_price(scorecard.payroll_paid_hours)}
    - Regular payroll: $#{format_price(scorecard.regular_payroll)}
    - Overtime hours: #{format_price(scorecard.overtime_hours)}
    - Overtime cost: $#{format_price(scorecard.overtime_cost)}
    - Total labor cost: $#{format_price(scorecard.total_labor_cost)}
    - Backlog tasks: #{scorecard.backlog_tasks}
    - Average customer loyalty: #{format_price(scorecard.average_customer_loyalty)}
    - Average customer satisfaction: #{format_price(scorecard.average_customer_satisfaction)}
    - At-risk customer segments: #{scorecard.at_risk_customer_segments}
    - Customer visits: #{scorecard.customer_visits}
    - Customer lifetime spend: $#{format_price(scorecard.customer_lifetime_spend)}
    - Local market share: #{format_price(scorecard.local_market_share_pct)}%
    - Competitor pressure: #{format_price(scorecard.competitor_pressure)}
    - Price reputation: #{scorecard.price_reputation}
    - Competitor reactions: #{scorecard.competitor_reactions}
    - Stockout units: #{scorecard.stockout_units}
    - Shrinkage units: #{scorecard.shrinkage_units}
    - Shrinkage loss: $#{format_price(scorecard.shrinkage_loss)}
    - Loss prevention score: #{scorecard.loss_prevention_score}
    - Loss prevention upgrades: #{scorecard.loss_prevention_upgrades}
    - Loss prevention spend: $#{format_price(scorecard.loss_prevention_spend)}
    - Online backorders: #{scorecard.online_backorders}
    - Service issues: #{scorecard.service_issues}
    - Rejections: #{scorecard.rejections}
    - Active failure modes: #{scorecard.active_failure_mode_count}
    - Failure modes: #{failure_mode_text(scorecard.failure_modes)}

    ## Artifacts

    - Final world: #{artifact_path(paths.final_world, paths, opts)}
    - Events: #{artifact_path(paths.events, paths, opts)}
    - Actions: #{artifact_path(paths.actions, paths, opts)}
    - Scorecard: #{artifact_path(paths.scorecard, paths, opts)}
    - Market: #{artifact_path(paths.market, paths, opts)}
    - Inventory: #{artifact_path(paths.inventory, paths, opts)}
    - Counterparty transcript: #{artifact_path(paths.counterparty_transcript, paths, opts)}
    - Replay JSON: #{artifact_path(paths.replay_json, paths, opts)}
    - Replay browser: #{artifact_path(paths.replay_html, paths, opts)}
    """
  end

  defp artifact_path(path, paths, opts) do
    if Keyword.get(opts, :deterministic_artifacts?, false) do
      Path.relative_to(path, Path.dirname(paths.report))
    else
      path
    end
  end

  defp failure_mode_text([]), do: "none"

  defp failure_mode_text(failure_modes) do
    failure_modes
    |> Enum.map(&get(&1, :id, "unknown"))
    |> Enum.join(", ")
  end

  defp jsonl(entries) do
    entries
    |> Enum.with_index()
    |> Enum.map(fn {entry, index} -> Jason.encode!(jsonable_artifact_entry(entry, index)) end)
    |> Enum.join("\n")
    |> then(fn
      "" -> ""
      content -> content <> "\n"
    end)
  end

  defp jsonable_artifact_entry(%{ts_ms: _} = entry, index) do
    entry |> jsonable() |> Map.put("ts_ms", index)
  end

  defp jsonable_artifact_entry(%{"ts_ms" => _} = entry, index) do
    entry |> jsonable() |> Map.put("ts_ms", index)
  end

  defp jsonable_artifact_entry(entry, _index), do: jsonable(entry)

  defp jsonable(%MapSet{} = value), do: value |> MapSet.to_list() |> jsonable()

  defp jsonable(%_{} = value), do: value |> Map.from_struct() |> jsonable()

  defp jsonable(%{} = value) do
    Enum.reduce(value, %{}, fn {key, val}, acc ->
      string_key = to_string(key)

      if is_atom(key) or not Map.has_key?(acc, string_key) do
        Map.put(acc, string_key, jsonable(val))
      else
        acc
      end
    end)
  end

  defp jsonable(value) when is_list(value), do: Enum.map(value, &jsonable/1)
  defp jsonable(value), do: value

  defp git_commit do
    case System.cmd("git", ["rev-parse", "HEAD"], stderr_to_stdout: true) do
      {commit, 0} -> String.trim(commit)
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp sha256(content), do: :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)

  defp html(value) do
    value
    |> to_string()
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
    |> String.replace("'", "&#39;")
  end

  defp format_price(price) when is_float(price), do: :erlang.float_to_binary(price, decimals: 2)

  defp format_price(price) when is_integer(price),
    do: :erlang.float_to_binary(price / 1, decimals: 2)

  defp format_price(price), do: to_string(price)

  defp get(map, key, default \\ nil)

  defp get(map, key, default) when is_map(map) and is_atom(key),
    do: Map.get(map, key, Map.get(map, Atom.to_string(key), default))

  defp get(map, key, default) when is_map(map), do: Map.get(map, key, default)
  defp get(_map, _key, default), do: default
end
