# lemon_platform_test

`lemon_platform_test` is Lemon's contract-test kit. Its ExUnit case templates run
behaviour-compliance suites against an extension implementation before it reaches a
user. The kit covers `LemonChannels.Plugin`, `LemonCore.SubagentRunner`,
`LemonCore.Store.Backend`, and `LemonMemory.Provider`.

Gateway engines are deliberately not an extension contract. The Gateway engine
behaviour, registry, `Echo` reference implementation, and `EngineCase` were removed
when Gateway moved to its configured singleton executor. Do not use this package to
add a top-level executor or vendor CLI to Gateway.

## Choose the correct extension point

| Need | Extension point |
| --- | --- |
| Integrate another model/API | `LemonAi.Provider` |
| Add agent capability | a `CodingAgent` tool |
| Run delegated external work | `LemonCore.SubagentRunner` |
| Add a messaging channel | `LemonChannels.Plugin` |
| Add a store or memory backend | `LemonCore.Store.Backend` or `LemonMemory.Provider` |

`LemonCore.SubagentRunner` is the delegated-task boundary. Vendor runners such as
Claude Code, Codex, Kimi, OpenCode, and Pi remain available there through
`lemon_cli_runners`; their resume formats remain supported by
`LemonCore.ResumeToken` and `LemonCore.ResumeFormats`. Top-level
`engine: "lemon"` is fixed compatibility provenance, while delegated tasks retain
their actual `task.engine` runner ID. Neither is a direct Gateway executor.

Each case template's moduledoc is the reference guide for its behaviour: the `use`
line, a minimal implementation, every suite option, and optional callbacks. The
suites test contracts rather than implementation internals and avoid network calls,
message delivery, and real task runs unless an explicit probe opts in.
