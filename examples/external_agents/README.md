# LemonSim External Agents

VendingBench can run one live simulation with an external agent process instead of an in-repo LLM model:

```bash
mix lemon.sim.vending_bench --preset ci --external-cmd "python3 examples/external_agents/baseline_agent.py" --artifact-dir /tmp/vb_external
mix lemon.sim.verify /tmp/vb_external
```

`--external-cmd` is mutually exclusive with `--model` and `--worker-model`. The command is spawned through the shell, so quoted commands such as `python3 agent.py --flag value` work.

## Protocol

Messages are UTF-8 JSON Lines over stdio. Each line is one JSON object.

On process start, the sim sends:

```json
{"type":"hello","protocol":"lemon_sim.external.v0","sim_id":"vb_1","scenario":"vending_bench","preset":"ci","seed":7,"max_days":7,"max_turns":25}
```

Suite runs start one fresh external process per competitor/seed run. Use
`seed` from the hello message to initialize any agent-side deterministic state.

For each operator decision, the sim sends:

```json
{"type":"decision_request","turn":1,"observation":{"system_prompt":"...","sections":[{"name":"world_state","text":"..."},{"name":"recent_events","text":"..."}]},"tools":[{"name":"wait_for_next_day","description":"...","parameters":{"type":"object","properties":{}}}]}
```

The external agent answers with one tool call. The `turn` value must echo the
current `decision_request.turn`:

```json
{"type":"tool_call","turn":1,"name":"check_balance","arguments":{}}
```

Support tools may repeat within one decision. After a support tool call, the sim sends:

```json
{"type":"tool_result","turn":1,"name":"check_balance","result":{"is_error":false,"text":"...","details":{}}}
```

A terminal tool ends the decision. VendingBench uses the same SingleTerminal policy as the LLM tool loop: support tools can precede the terminal action, and one terminal action ends the turn. The same `decision_max_turns` bound applies to the support-tool loop.

Responses whose `turn` does not match the active decision are treated as stale
and ignored until the decision timeout expires. For v0 compatibility, responses
without `turn` are still accepted, but omission can desynchronize a slow agent:
a late response from one decision may be consumed by the next decision.

The sim uses Erlang line-mode ports and reassembles `:noeol` fragments before
decoding JSON, so responses may exceed the 64 KiB port fragment size. There is
no protocol-level line-size cap; oversized responses are bounded by the decision
timeout and available process memory.

At run end, the sim sends:

```json
{"type":"game_over","reason":"run_complete"}
```

Then stdin is closed.

## Compete In A Suite

External competitors use `external_cmd` in the suite competitor spec:

```json
{"id":"my-agent","external_cmd":"python3 my_agent.py"}
```

From the Mix task, pass one or more external commands alongside offline or live
competitors:

```bash
mix lemon.sim.suite --scenario vending_bench --preset ci --seeds 7,8 --offline baseline --external-cmd "python3 examples/external_agents/baseline_agent.py" --out /tmp/vb-suite
```

External suite runs are ranked by the same verified scenario metric as every
other competitor. Token usage is reported as zero and cost is shown as unknown,
not `$0.00`, because LemonSim cannot know an external agent's upstream spend.

## Failure Semantics

- Agent process exit or stdout close is treated as an empty response.
- Invalid JSON or a JSON object that is not a valid `tool_call` is treated as a malformed turn.
- No response before the decision timeout is treated as a live step timeout.
- Too many support-tool rounds is treated as max turns exceeded.

VendingBench degrades these failures into `action_rejected` events or auto-wait recovery where its live-run recovery policy already does so.

## Security

External agent v0 has no sandboxing. The command runs with the same operating-system privileges, environment, filesystem access, and network access as the user running `mix`.
