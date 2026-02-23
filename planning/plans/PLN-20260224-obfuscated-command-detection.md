# Plan: Obfuscated Command Detection

## Metadata
- **Plan ID**: PLN-20260224-obfuscated-command-detection
- **Status**: landed
- **Created**: 2026-02-24
- **Author**: agent
- **Workspace**: feature/obfuscated-command-detection
- **Change ID**: pending

## Summary
Port OpenClaw's obfuscated command detection (commit 0e28e50b4) into Lemon's bash and exec tools. Detects shell obfuscation techniques that could be used to bypass exec approval/allowlist filters, and rejects commands before execution with a clear error message.

## Scope
### In Scope
- New `CodingAgent.Tools.ExecSecurity` module with pattern-based obfuscation detection
- Integration into `CodingAgent.Tools.Bash` (`do_execute`)
- Integration into `CodingAgent.Tools.Exec` (`do_execute`)
- Detection of: backtick substitution, `$(...)` command substitution, `${VAR}` braced variable substitution, `$VAR` simple variable substitution, empty single-quote concatenation (`x''y`), empty double-quote concatenation (`x""y`)
- 45 tests covering all patterns (unit + bash integration)

### Out of Scope
- Allowlist-based command filtering (Lemon does not have one yet)
- Exec tool integration tests (exec integration requires ProcessManager; covered by unit tests)
- Gateway-level enforcement (exec_security is called at tool level, enforced on all paths)

## Success Criteria
- [x] `ExecSecurity.check/1` detects all six obfuscation pattern families
- [x] `Bash.execute/6` rejects obfuscated commands before spawning any process
- [x] `Exec.execute/6` rejects obfuscated commands before spawning any process
- [x] Clear rejection message includes the detected technique name
- [x] Clean commands pass through unmodified
- [x] 45 tests, 0 failures

## Implementation Notes

### New Module: `ExecSecurity`
`apps/coding_agent/lib/coding_agent/tools/exec_security.ex`

Public API:
- `check/1` — returns `:ok` or `{:obfuscated, technique_description}`
- `rejection_message/1` — returns a human-readable string for the tool result

Detection is done via a reduce-while over six dedicated private detector functions, each using a `Regex.match?/2` guard. First match wins and short-circuits.

### Bash Integration
`do_execute/5` was split into `do_execute/5` (security gate) + `do_execute_checked/6` (original logic). The gate calls `ExecSecurity.check/1` and returns an `AgentToolResult` with `details: %{error: :obfuscated_command}` if obfuscation is detected.

### Exec Integration
`do_execute/2` was split into `do_execute/2` (security gate) + `do_execute_validated/6` (original `with` validation chain). Same pattern as bash.

### Pattern Decisions
- `$VAR` (simple substitution): `~r/\$[A-Za-z_][A-Za-z0-9_]*/` — does NOT match `$1` (positional parameters, not a bypass risk) or bare `$`
- Backticks: `~r/`[^`]+`/` — requires at least one character between backticks; empty ` `` ` is not flagged
- Concatenation: `~r/[A-Za-z]''[A-Za-z]/` — requires letters on both sides; lone `''` in an argument (e.g. `echo ''`) is not flagged

## Progress Log
| Timestamp | Who | What | Result | Links |
|-----------|-----|------|--------|-------|
| 2026-02-24 13:05 | agent | Implemented ExecSecurity module, bash/exec integration, 45 tests | 45 tests pass | - |

## Related
- Source idea: [IDEA-20260224-openclaw-obfuscated-command-detection](../ideas/IDEA-20260224-openclaw-obfuscated-command-detection.md)
- Source: OpenClaw commit 0e28e50b4
