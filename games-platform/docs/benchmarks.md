# Performance Benchmarks

This document describes the performance benchmark suite for the Lemon agent runtime.

## Overview

The benchmark suite measures critical paths in the agent runtime to help:

- Identify performance bottlenecks
- Track performance regressions
- Validate optimization efforts
- Understand system behavior under load

Benchmarks use [Benchee](https://hex.pm/packages/benchee), an Elixir benchmarking library.

## Benchmark Locations

| App | Directory |
|-----|-----------|
| agent_core | `apps/agent_core/bench/` |
| coding_agent | `apps/coding_agent/bench/` |

## Running Benchmarks

### Prerequisites

The `benchee` dependency is included in dev/test environments. If needed:

```bash
mix deps.get
```

### Quick Verification

Run quick checks to verify the benchmark infrastructure works:

```bash
# AgentCore quick check
cd apps/agent_core && mix run bench/quick_check.exs

# CodingAgent quick check
cd apps/coding_agent && mix run bench/quick_check.exs
```

### Individual Benchmarks

```bash
# AgentCore benchmarks
cd apps/agent_core
mix run bench/event_stream_bench.exs
mix run bench/tool_task_bench.exs
mix run bench/registry_bench.exs

# CodingAgent benchmarks
cd apps/coding_agent
mix run bench/session_bench.exs
mix run bench/tool_dispatch_bench.exs
```

### All Benchmarks

```bash
cd apps/agent_core && mix run bench/all_bench.exs
```

### From Project Root

```bash
mix run -r apps/agent_core/bench/event_stream_bench.exs
mix run -r apps/coding_agent/bench/session_bench.exs
```

## AgentCore Benchmarks

### event_stream_bench.exs

Measures EventStream performance:

| Scenario | Description |
|----------|-------------|
| Synchronous push | `EventStream.push/2` latency |
| Asynchronous push | `EventStream.push_async/2` latency |
| Consumer read (100) | Reading 100 events via `events/1` |
| Consumer read (1000) | Reading 1000 events |
| Queue depth impact | Push latency with 0, 100, 1000 events queued |
| Drop strategies | Overhead of drop_oldest vs drop_newest |

### tool_task_bench.exs

Measures tool task execution:

| Scenario | Description |
|----------|-------------|
| Bare Task.async | Raw task spawning overhead |
| Task.Supervisor | Supervised task overhead |
| Parallel (1 tool) | Single tool execution |
| Parallel (3 tools) | 3 concurrent tools with result collection |
| Parallel (10 tools) | 10 concurrent tools |
| CPU-bound tasks | Parallelization benefits for compute |
| Message patterns | Single, batch, GenServer call comparison |

### registry_bench.exs

Measures registry operations:

| Scenario | Description |
|----------|-------------|
| Lookup hit | Finding registered process |
| Lookup miss | Looking up non-existent key |
| Register/unregister | Full lifecycle |
| List (100 entries) | Listing with 100 registered keys |
| ETS comparison | Direct ETS vs Registry performance |
| Process dict | Process dictionary comparison |

## CodingAgent Benchmarks

### session_bench.exs

Measures session operations:

| Scenario | Description |
|----------|-------------|
| Tool set init (coding) | Initializing full coding tool set |
| Tool set init (read-only) | Initializing read-only tools |
| Message conversion | `to_llm` transformation |
| Registry operations | Session registry lookup/register |
| JSON serialization (small) | Persisting 10 messages |
| JSON serialization (medium) | Persisting 50 messages |
| JSON serialization (large) | Persisting 200 messages |

### tool_dispatch_bench.exs

Measures tool dispatch:

| Scenario | Description |
|----------|-------------|
| Tool lookup (map) | Map-based tool lookup |
| Tool lookup (list) | List-based tool lookup |
| Tool lookup (helper) | Helper function lookup |
| Execution dispatch | Tool execution overhead |
| Result formatting | Result to JSON conversion |
| End-to-end | Full tool call simulation |

## Interpreting Results

Benchee output includes:

| Metric | Description |
|--------|-------------|
| **ips** | Iterations per second (higher is better) |
| **average** | Mean execution time |
| **deviation** | Standard deviation as percentage |
| **median** | Middle value (50th percentile) |
| **99th %** | 99th percentile latency |

### Example Output

```
Name                          ips        average  deviation         median         99th %
registry_lookup          833.54 K        1.20 us  +/-2280.29%        0.95 us        1.29 us
event_stream_push         27.87 K       35.88 us   +/-830.18%       21.18 us       47.93 us
```

### High Deviation

High deviation (>100%) often indicates:
- GC interference (BEAM garbage collection)
- Scheduler variance
- System load
- Cold cache effects

Run benchmarks on idle systems for more consistent results.

## Performance Baseline

Representative numbers from development machines (your results may vary):

### AgentCore

| Operation | Typical Latency |
|-----------|-----------------|
| Registry lookup | ~1 us |
| EventStream push (sync) | ~20-40 us |
| EventStream push (async) | ~5-10 us |
| Tool task spawn | ~50-100 us |
| Parallel tools (3) | ~200-500 us |

### CodingAgent

| Operation | Typical Latency |
|-----------|-----------------|
| Tool set init (15 tools) | ~300 us |
| Message conversion | ~200 ns |
| JSON encode (50 messages) | ~50 us |
| Session registry lookup | ~1 us |
| Tool dispatch | ~1-5 us |

## Adding New Benchmarks

1. Create a new `.exs` file in the appropriate `bench/` directory
2. Use `Benchee.run/2` with descriptive scenario names
3. Include setup/cleanup code outside the measured function
4. Add to `all_bench.exs` if it should run with combined benchmarks

### Template

```elixir
#!/usr/bin/env elixir
#
# MyFeature Benchmarks
#
# Run with:
#   cd apps/my_app && mix run bench/my_feature_bench.exs

IO.puts("MyFeature Benchmarks")
IO.puts("====================\n")

# Setup code (not measured)
setup_data = prepare_data()

Benchee.run(
  %{
    "scenario_1" => fn ->
      # Code to benchmark
      MyModule.function_1(setup_data)
    end,
    "scenario_2" => fn ->
      MyModule.function_2(setup_data)
    end,
    "scenario_3" => {
      fn input -> MyModule.function_3(input) end,
      before_each: fn _ -> generate_input() end
    }
  },
  time: 5,           # Run each scenario for 5 seconds
  warmup: 2,         # 2 second warmup
  memory_time: 2,    # Also measure memory
  print: [fast_warning: false]
)
```

### Tips

- Run on idle systems for consistent results
- Use `memory_time: 2` to also measure memory allocation
- Increase `time:` for more stable results on noisy systems
- Use `before_each:` for input that should be regenerated
- Compare before/after when optimizing specific code paths

## Continuous Monitoring

Consider integrating benchmarks into CI:

```yaml
# .github/workflows/benchmark.yml
benchmark:
  runs-on: ubuntu-latest
  steps:
    - uses: actions/checkout@v4
    - uses: erlef/setup-beam@v1
      with:
        elixir-version: '1.16'
        otp-version: '26'
    - run: mix deps.get
    - run: mix run apps/agent_core/bench/quick_check.exs
```

For regression detection, consider using [benchee_html](https://hex.pm/packages/benchee_html) to generate comparison reports.
