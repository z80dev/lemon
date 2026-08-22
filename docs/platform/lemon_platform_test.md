# lemon_platform_test

`lemon_platform_test` is Lemon's contract-test kit. Its ExUnit case templates run
behaviour-compliance suites against an extension implementation before it reaches a
user. The kit covers `LemonChannels.Plugin`, `LemonCore.Store.Backend`, and
`LemonMemory.Provider`.

Gateway engines are deliberately not an extension contract. The Gateway engine
behaviour, registry, `Echo` reference implementation, and `EngineCase` were removed
when Gateway moved to its configured singleton executor. Do not use this package to
add a top-level executor or vendor CLI to Gateway.

## Choose the correct extension point

| Need | Extension point |
| --- | --- |
| Integrate another model/API | `LemonAi.Provider` |
| Add agent capability | a `CodingAgent` tool |
| Run delegated work | a native in-process subagent (`CodingAgent.Session` via the `task` tool) |
| Add a messaging channel | `LemonChannels.Plugin` |
| Add a store or memory backend | `LemonCore.Store.Backend` or `LemonMemory.Provider` |

Delegated tasks run natively in-process: a subagent is a child
`CodingAgent.Session` coordinated by `CodingAgent.Coordinator`, and there are no
vendor CLI runners (Claude Code, Codex, Kimi, OpenCode, and Pi were removed).
Top-level `engine: "lemon"` is fixed compatibility provenance, while a
delegated task retains its own task identity. Neither is a direct Gateway
executor.

Each case template's moduledoc is the reference guide for its behaviour: the `use`
line, a minimal implementation, every suite option, and optional callbacks. The
suites test contracts rather than implementation internals and avoid network calls,
message delivery, and real task runs unless an explicit probe opts in.
