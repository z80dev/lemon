defmodule LemonSim.Examples.VendingBench.World do
  @moduledoc false

  alias LemonSim.Examples.VendingBench.{DemandModel, Suppliers}

  @default_max_days 30
  @default_starting_balance 500.0

  @spec initial_world(keyword()) :: map()
  def initial_world(opts \\ []) do
    max_days = Keyword.get(opts, :max_days, @default_max_days)
    seed = Keyword.get(opts, :seed, :erlang.phash2(:erlang.monotonic_time()))
    starting_balance = Keyword.get(opts, :starting_balance, @default_starting_balance)

    catalog = DemandModel.catalog()

    rows = ~w(A B C D)
    cols = ~w(1 2 3)

    slots =
      for row <- rows, col <- cols, into: %{} do
        slot_id = "#{row}#{col}"
        slot_type = if row in ~w(A B), do: "small", else: "large"
        {slot_id, %{slot_type: slot_type, item_id: nil, inventory: 0, price: nil}}
      end

    weather = DemandModel.generate_weather(1, seed)
    season = DemandModel.season_for_day(1)
    operator_model = Keyword.get(opts, :model)
    physical_worker_model = Keyword.get(opts, :physical_worker_model, operator_model)

    %{
      status: "in_progress",
      phase: "operator_turn",
      active_actor_id: "operator",
      day_number: 1,
      time_minutes: 9 * 60,
      minutes_per_day: 24 * 60,
      max_days: max_days,
      seed: seed,
      bank_balance: starting_balance,
      cash_in_machine: 0.0,
      daily_fee: 2.0,
      unpaid_fee_streak: 0,
      machine: %{
        rows: 4,
        cols: 3,
        slots: slots
      },
      storage: %{
        inventory: %{},
        batches: [],
        capacity_units: Keyword.get(opts, :storage_capacity_units, 160),
        spoiled_units: 0,
        overflow_units: 0,
        spoilage_loss: 0.0
      },
      catalog: catalog,
      supplier_directory: Suppliers.directory(),
      supplier_threads: %{},
      supplier_order_history: [],
      supplier_quote_history: [],
      inbox: [],
      outbox: [],
      market_research_history: [],
      supplier_research_history: [],
      supplier_reply_history: [],
      supplier_incident_history: [],
      arena_mailbox: [],
      arena_outbox: [],
      arena_payments_sent: [],
      arena_payments_received: [],
      arena_trades: [],
      arena_supplier_leads: [],
      arena_price_wars: [],
      arena_collusion_signals: [],
      pending_deliveries: [],
      pending_refunds: [],
      reminders: [],
      customer_complaints: [],
      refunds_paid: 0.0,
      recent_sales: [],
      sales_history: [],
      weather: weather,
      season: season,
      operator_run_count: 0,
      physical_worker_run_count: 0,
      operator_model: operator_model,
      physical_worker_model: physical_worker_model,
      runtime_models: runtime_models(operator_model, physical_worker_model),
      operator_memory_namespace: "#{Keyword.get(opts, :sim_id, "vb")}/operator",
      physical_worker_memory_namespace: "#{Keyword.get(opts, :sim_id, "vb")}/physical_worker",
      physical_worker_last_report: nil,
      physical_worker_history: [],
      machine_fault_reports: [],
      price_change_count: 0,
      coordination_failures: 0,
      journals: %{}
    }
  end

  def runtime_models(operator_model, physical_worker_model) do
    %{
      operator: model_descriptor(operator_model),
      physical_worker: model_descriptor(physical_worker_model)
    }
  end

  defp model_descriptor(nil), do: nil

  defp model_descriptor(%{} = model) do
    provider = get(model, :provider)
    id = get(model, :id, get(model, :name))
    label = model_label(provider, id)

    %{
      provider: model_part(provider),
      id: model_part(id),
      label: label
    }
  end

  defp model_descriptor(model),
    do: %{provider: nil, id: model_part(model), label: model_part(model)}

  defp model_label(provider, id) do
    provider = model_part(provider)
    id = model_part(id)

    cond do
      id in [nil, ""] ->
        provider

      provider in [nil, ""] ->
        id

      String.starts_with?(id, provider <> ":") ->
        id

      true ->
        provider <> ":" <> id
    end
  end

  defp model_part(nil), do: nil
  defp model_part(value) when is_atom(value), do: Atom.to_string(value)
  defp model_part(value) when is_binary(value), do: value
  defp model_part(value), do: to_string(value)

  defp get(map, key) when is_map(map) and is_atom(key),
    do: Map.get(map, key, Map.get(map, Atom.to_string(key)))

  defp get(_map, _key), do: nil

  defp get(map, key, default) when is_map(map) and is_atom(key),
    do: Map.get(map, key, Map.get(map, Atom.to_string(key), default))

  defp get(_map, _key, default), do: default
end
