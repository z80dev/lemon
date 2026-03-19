# Vending Bench Implementation Spec

> Status: draft
> Owner: codex
> Last updated: 2026-03-18
> Purpose: persistent design doc for a Lemon-native Vending Bench implementation that can be resumed across sessions.

## 1. Goal

Build a Lemon-native `lemon_sim` domain inspired by Vending Bench with:

- a main operator agent for business decisions
- a separate physical-worker subagent for on-site machine tasks
- updater-owned authoritative world state
- separate memory for operator and worker
- optional separate models for operator and worker
- support for later multi-agent Arena-style competition

This is a Lemon-native benchmark, not a claim of exact Andon Labs parity. The original benchmark has closed-source details we cannot reproduce exactly.

## 2. Key Decisions

### 2.1 Domain home

The implementation lives in `apps/lemon_sim`, not `apps/coding_agent`.

Reason:

- `lemon_sim` already matches the required architecture: `ActionSpace`, `Projector`, `Runner`, `Updater`, `Performance`
- `coding_agent` subagents are built for workspace delegation, not simulation-state delegation
- `lemon_sim` already depends on `agent_core`, so a real child agent is available without pulling in coding-session semantics

### 2.2 Physical worker shape

The physical worker should be a real `AgentCore` child agent spawned by a terminal operator tool such as `run_physical_worker`.

Reason:

- preserves the original benchmark stressor of delegation
- gives the worker its own transcript, memory, and model
- allows operator/worker coordination failures to become benchmark signal

### 2.3 State authority

The worker must not mutate the sim world directly.

Reason:

- all world changes should continue to flow through `Updater.apply_event/3`
- tool calls return event payloads
- updater remains the single source of truth

### 2.4 Memory model

Use LemonSim file-backed memory namespaces instead of transcript-only memory.

Namespaces:

- operator: `sim_id/operator`
- physical worker: `sim_id/physical_worker`

### 2.5 Initial scope

Start with a constrained single-machine benchmark:

- 1 operator
- 1 physical worker
- honest suppliers only
- 30-day runs
- no inter-machine competition yet
- no adversarial refunds/negotiation in phase 1

## 3. Architecture

### 3.1 Top-level flow

1. `LemonSim.Runner.step/3` asks the operator to act.
2. Operator uses support tools for lookups and memory.
3. Operator ends the turn with one terminal action:
   - `send_supplier_email`
   - `run_physical_worker`
   - `wait_for_next_day`
4. Terminal tool returns event payloads.
5. `Updater.apply_event/3` applies those events.
6. Updater may advance time, trigger day rollover, resolve sales, and enqueue new inbox items.
7. Loop repeats until terminal condition.

### 3.2 Physical worker flow

1. Operator calls `run_physical_worker` with instructions.
2. The tool spawns an `AgentCore` child agent with worker-only tools.
3. Worker receives:
   - worker system prompt
   - operator instructions
   - current machine/storage view
   - worker memory tools
4. Worker performs a short bounded run.
5. Worker output is converted into a batch of worker events.
6. Parent tool returns summary text plus those events.
7. Updater applies events and charges worker-trip time cost.

Implementation note:

- the parent must subscribe to the worker `AgentCore` event stream and collect
  `tool_execution_end` / `turn_end` events from the real child agent run

### 3.3 Why not `coding_agent` task sessions?

Do not use `CodingAgent.Tools.Task` or `CodingAgent.Coordinator` for the simulation worker.

Reason:

- wrong prompt/tool model
- wrong persistence semantics
- would couple simulation logic to coding-session concerns
- `AgentCore` is the thinner and more appropriate runtime primitive

## 4. Proposed Modules

### 4.1 `lemon_sim`

- `apps/lemon_sim/lib/lemon_sim/examples/vending_bench.ex`
- `apps/lemon_sim/lib/lemon_sim/examples/vending_bench/action_space.ex`
- `apps/lemon_sim/lib/lemon_sim/examples/vending_bench/updater.ex`
- `apps/lemon_sim/lib/lemon_sim/examples/vending_bench/events.ex`
- `apps/lemon_sim/lib/lemon_sim/examples/vending_bench/performance.ex`
- `apps/lemon_sim/lib/lemon_sim/examples/vending_bench/demand_model.ex`
- `apps/lemon_sim/lib/lemon_sim/examples/vending_bench/suppliers.ex`
- `apps/lemon_sim/lib/lemon_sim/examples/vending_bench/physical_worker.ex`
- `apps/lemon_sim/lib/mix/tasks/lemon.sim.vending_bench.ex`

### 4.2 `lemon_sim_ui`

- `apps/lemon_sim_ui/lib/lemon_sim_ui/live/components/vending_bench_board.ex`

Plus wiring in:

- `SimManager`
- `SimHelpers`
- `SimDashboardLive`

## 5. World Schema

This is the initial target `world` shape. Keys may evolve, but this should remain the canonical starting point.

```elixir
%{
  status: "in_progress",
  phase: "operator_turn",
  active_actor_id: "operator",
  day_number: 1,
  time_minutes: 9 * 60,
  minutes_per_day: 24 * 60,
  max_days: 30,
  bank_balance: 500.0,
  cash_in_machine: 0.0,
  daily_fee: 2.0,
  unpaid_fee_streak: 0,
  machine: %{
    rows: 4,
    cols: 3,
    slots: %{
      "A1" => %{slot_type: "small", item_id: nil, inventory: 0, price: nil},
      "A2" => %{slot_type: "small", item_id: nil, inventory: 0, price: nil}
    }
  },
  storage: %{
    inventory: %{}
  },
  catalog: %{
    "sparkling_water" => %{
      display_name: "Sparkling Water",
      size_class: "small",
      wholesale_cost: 1.25,
      reference_price: 2.50,
      elasticity: 1.1,
      base_daily_sales: 4
    }
  },
  supplier_directory: %{},
  supplier_threads: %{},
  inbox: [],
  pending_deliveries: [],
  pending_refunds: [],
  customer_complaints: [],
  recent_sales: [],
  sales_history: [],
  weather: %{kind: "mild", demand_multiplier: 1.0},
  season: %{month: 1, demand_multiplier: 1.0},
  operator_run_count: 0,
  physical_worker_run_count: 0,
  operator_model: nil,
  physical_worker_model: nil,
  operator_memory_namespace: nil,
  physical_worker_memory_namespace: nil,
  physical_worker_last_report: nil,
  physical_worker_history: [],
  journals: %{}
}
```

## 6. Tool Surface

## 6.1 Operator support tools

These are support tools under LemonSim's single-terminal tool policy.

- `read_inbox`
- `check_balance`
- `check_storage`
- `inspect_supplier_directory`
- `review_recent_sales`
- `memory_read_file`
- `memory_write_file`
- `memory_patch_file`
- `memory_list_files`
- `memory_delete_file`

## 6.2 Operator terminal tools

- `send_supplier_email`
- `run_physical_worker`
- `wait_for_next_day`

Only one terminal tool may be called per decision turn.

## 6.3 Physical worker support tools

- `get_inventory`
- `memory_read_file`
- `memory_write_file`
- `memory_patch_file`
- `memory_list_files`
- `memory_delete_file`

## 6.4 Physical worker terminal tools

- `finish_visit`

Worker run rule:

- the worker can use support tools plus multiple operational actions during one visit:
  `stock_products`, `collect_cash`, `set_price`
- `finish_visit` is the explicit final action that ends the visit
- operational actions must update only the worker's local visit view; authoritative world mutation still happens in the updater from emitted events

## 7. Time Model

Track explicit simulated time in minutes.

Initial time costs:

- quick lookup support tool: `+5`
- supplier email / search-like business action: `+25`
- physical worker visit: `+75`
- `wait_for_next_day`: jump to next morning

Operational guardrail:

- physical worker visits must start no later than `15:45`
- do not allow dispatches that would keep the worker on-site past `17:00`
- enforce this in both the operator tool and the updater so crafted event batches cannot bypass it

Design note:

- time cost is applied by the updater, not by the tool implementation directly
- tool implementations return events
- updater interprets event kind and increments `time_minutes`
- deliveries scheduled for day `D` are added to storage during the overnight
  rollover into day `D`

## 8. Day Rollover

When time crosses the day boundary, updater should execute a deterministic rollover sequence:

1. resolve customer demand and sales
2. add proceeds to `cash_in_machine`
3. generate supplier replies into `inbox`
4. resolve deliveries into `pending_deliveries` or `storage`
5. generate customer complaints or refund requests if applicable
6. deduct daily fee from `bank_balance`
7. increment `unpaid_fee_streak` if fee cannot be paid
8. update weather and seasonal multipliers
9. increment `day_number`
10. reset `time_minutes` to start-of-day

Bankruptcy condition:

- if unpaid daily fees reach threshold, terminal state

## 9. Event Contract

All tool activity should become explicit events.

## 9.1 Operator events

- `operator_checked_balance`
- `operator_checked_storage`
- `operator_read_inbox`
- `supplier_email_sent`
- `physical_worker_run_requested`
- `next_day_waited`

## 9.2 Physical worker events

- `physical_worker_started`
- `machine_inventory_checked`
- `machine_stocked`
- `cash_collected`
- `price_set`
- `physical_worker_finished`

## 9.3 System events

- `day_advanced`
- `daily_fee_charged`
- `sale_realized`
- `delivery_arrived`
- `supplier_reply_received`
- `refund_requested`
- `refund_paid`
- `weather_changed`
- `bankruptcy_triggered`
- `game_over`
- `action_rejected`

## 10. `run_physical_worker` Tool Contract

The operator terminal tool should accept:

```json
{
  "instructions": "Go to the machine, collect cash, then stock sparkling water if needed."
}
```

Expected behavior:

1. build worker prompt from:
   - operator instructions
   - current machine/storage snapshot
   - worker system prompt
2. spawn worker agent
3. wait for worker completion
4. extract worker tool-call results
5. translate them into LemonSim events
6. return:
   - summary text
   - event batch
   - worker report metadata

Expected result details shape:

```elixir
%{
  "events" => [...],
  "worker_report" => %{
    "summary" => "...",
    "tool_calls" => [...],
    "memory_namespace" => "sim_id/physical_worker"
  }
}
```

The authoritative `physical_worker_finished` event should carry the same report
fields needed for persistence, so `physical_worker_last_report` /
`physical_worker_history` in world state keep the worker summary plus audit
metadata instead of dropping it after tool execution.

## 11. `physical_worker.ex`

This module should own the nested-agent runtime wrapper.

Responsibilities:

- construct worker tools
- configure worker model
- attach worker memory namespace
- spawn agent under `AgentCore.SubagentSupervisor`
- subscribe to worker events if needed
- wait for completion
- collect final transcript or state summary
- convert worker output into `machine_stocked` / `cash_collected` / `price_set` events

Non-goals:

- direct mutation of sim world
- use of `coding_agent` sessions
- unbounded worker loops

Initial constraints:

- worker `max_turns`: 5
- one visit per operator terminal action
- worker tool set is strictly limited

## 12. Projection Plan

## 12.1 Operator projector sections

- `business_state`
- `machine_snapshot`
- `storage_snapshot`
- `supplier_threads`
- `inbox`
- `sales_summary`
- `worker_status`
- `recent_events`
- `memory`
- `available_actions`
- `decision_contract`

## 12.2 Worker projector sections

- `machine_snapshot`
- `storage_snapshot`
- `operator_instructions`
- `worker_memory`
- `available_actions`
- `decision_contract`

The worker does not need full business context. Keep the worker prompt narrow and operational.

## 13. Memory Plan

Operator memory should store:

- supplier shortlists
- item performance notes
- pricing strategy
- to-do reminders
- delivery expectations

Worker memory should store:

- machine layout observations
- recurring stocking heuristics
- recent on-site issues

Important:

- separate namespaces are intentional
- operator and worker should not silently share a single note space

## 14. Model Configuration

Initial run options:

- `:operator_model`
- `:operator_stream_options`
- `:physical_worker_model`
- `:physical_worker_stream_options`

Defaults:

- if worker model is not set, use operator model

Later benchmark dimensions:

- strong planner + cheap worker
- cheap planner + strong worker
- same model in both roles

## 15. Performance Metrics

`Performance.summarize/1` should report:

- `net_worth`
- `cash_on_hand`
- `cash_in_machine`
- `inventory_value_wholesale`
- `units_sold`
- `days_without_sales`
- `average_margin`
- `refunds_paid`
- `stockout_count`
- `price_change_count`
- `supplier_count_used`
- `worker_trip_count`
- `coordination_failures`
- `bankruptcy_day`

Phase 1 success criterion:

- net worth greater than starting balance after 30 days

## 16. UI Plan

`VendingBenchBoard` should show:

- bank balance
- cash trapped in machine
- current day and time
- machine slot grid
- storage inventory
- pending deliveries
- inbox summary
- recent sales
- worker last report

No human-play interaction is needed in phase 1.

## 17. Phase Plan

## Phase 1

Goal:

- single-machine MVP with operator + physical worker split

Includes:

- world schema
- operator action space
- physical worker nested runtime
- basic demand model
- honest suppliers
- 30-day runs
- performance summary
- mix task

Excludes:

- adversarial suppliers
- refunds
- negotiation
- Arena competition

## Phase 2

Goal:

- richer supply interactions and stronger benchmark signal

Includes:

- supplier email threads
- delayed deliveries
- separate operator/worker models
- worker report persistence
- repeated benchmark runner with aggregated results

## Phase 3

Goal:

- approximate Vending Bench v2 pressure

Includes:

- adversarial suppliers
- refunds
- seasonal and weather effects
- stronger memory stress

## Phase 4

Goal:

- Arena-style competition

Includes:

- multiple machines
- one operator + one worker per machine
- shared demand pool
- visible competitor prices and stock
- model-vs-model head-to-head evaluation

## 18. Open Questions

- Should `search_suppliers` exist in phase 1, or should supplier discovery be a fixed directory?
- Should `read_inbox` be a support lookup only, or should it also acknowledge/process messages?
- Should deliveries land directly in storage or in a pending-delivery queue requiring worker pickup?
- Should `set_price` change one slot at a time or multiple slots in one visit?
- Should `run_physical_worker` allow multiple worker terminal actions in one child run, or exactly one?
- How should coordination failures be counted objectively?
- Do we want deterministic seeds by default for benchmark repeatability?

## 19. Current Recommendation

Start narrow:

- one operator terminal action per turn
- one bounded worker visit per `run_physical_worker`
- updater handles all time costs and day rollover
- honest suppliers only
- fixed item catalog
- separate operator and worker memory namespaces

This preserves the benchmark's delegation pressure without overbuilding phase 1.

## 20. Session Log

### 2026-03-17

- reviewed `docs/product/vending_bench_research.md`
- decided to implement as a `lemon_sim` domain
- decided against using `coding_agent` task sessions for the physical worker
- decided to use a real `AgentCore` child agent for the physical worker
- established initial module layout, world schema, tool surface, event contract, and phase plan
