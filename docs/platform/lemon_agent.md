# lemon_agent

**Status:** stub — package not yet carved out. Plan of record: [../platform-split.md](../platform-split.md).

`lemon_agent` is the agent itself: the agent loop, the tool registry and tool contract,
subagents, the model runtime, the CLI runners, and the workspace stores (goals, kanban,
heartbeats) that multiple agents use to coordinate work. It depends on `lemon_ai` and
`lemon_core` and nothing else in the platform, which makes it the package a third party
starts from when building their own agent. This page will become the package README:
defining a tool, driving the loop, spawning subagents, and the `LemonAgent.Workspace.*`
stores. Source today is `apps/lemon_agent` plus three stores moving out of `lemon_core`.
