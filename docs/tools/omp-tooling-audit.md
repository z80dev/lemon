# OMP Tooling Audit

This audit compares Lemon's native coding tools with the Oh My Pi (OMP) coding-agent
tool surface. The upstream snapshot reviewed on 2026-08-30 was commit
[`51f0380`](https://github.com/can1357/oh-my-pi/commit/51f03804476c3fd3c15748ae07e4849d1efc883b).
The comparison is source-based rather than inferred from tool names.

## Outcome

Lemon already has strong equivalents for the core coding loop: file reads, exact and
hashline edits, patching, shell/process execution, grep/find, checkpoints, web and
browser work, media analysis, memory, todos/Kanban, and native subagents. The first
improvements taken from this audit focus on mutation correctness:

- Local `patch` now prepares every hunk in memory before the first write, rejects
  duplicate paths and existing move destinations, revalidates each operation just
  before commit, and exclusively creates new targets. Commits remain sequential;
  failures report any already-committed prefix and possibly changed current paths
  instead of attempting rollback over concurrent filesystem changes.
- Local `write` now canonicalizes the path used for validation and mutation, then
  rejects symlink targets, caller-controlled symlinked parents below the trusted
  mutation boundary, directories, devices, and other special files by default.
  Trusted internal callers can retain the older follow-symlink behavior with
  `allow_symlinks: true`.

ACP-backed patch/write operations keep their remote-client semantics. Local preflight
reduces partial mutations caused by invalid hunks, but does not claim batch atomicity,
cross-process inode safety, or rollback of a committed prefix.

## Capability Map

| OMP surface | Lemon status | Notes |
|-------------|--------------|-------|
| `read` | Present | Lemon supports bounded reads and untrusted-result fencing. OMP additionally invests in structural summaries and read provenance. |
| `write` | Present, hardened | Lemon adds checkpoints, diagnostics, optional formatting, ACP writes, and now local target-type validation. OMP additionally supports archive/SQLite/device targets and permission-fallback handlers. |
| model-selected `edit` modes | Partial | Lemon exposes `edit`, `patch`, and `hashline_edit` as separate tools. OMP selects replace, patch, apply-patch, or hashline behind one edit concept and supports per-model variants. |
| multi-file patch preflight | Present, hardened | Lemon preflights all local hunks, revalidates each operation, exclusively creates new targets, and reports any committed prefix plus possibly changed current paths. OMP's hashline `Patcher` preflights all sections and reports any prefix written by an I/O failure. |
| `grep` / `glob` | Equivalent | Lemon's `grep` plus `find` cover text and path discovery; a separate `glob` name is not required for capability parity. |
| `bash` / `eval` / `hub` | Mostly present | Lemon has supervised shell/process execution and config-gated `execute_code`. OMP's `hub` provides a more unified long-lived process/device surface. |
| `lsp` | Important gap | Lemon exposes diagnostics and has lower-level supervised JSON-RPC infrastructure, but lacks one default model-facing tool for definitions, references, hover, rename, code actions, and workspace edits. |
| `ast_grep` / `ast_edit` | Gap | Lemon can call external tools through the shell, but has no structured, policy-aware AST search/edit contract or staged AST proposal flow. |
| `github` | Gap with fallback | Lemon can use `gh` through shell execution; OMP has a purpose-built structured GitHub tool. |
| `security_scan` | Gap | Lemon has safety controls and can run repository scanners, but no single model-facing structured scan/remediation tool. |
| `inspect_image` | Equivalent | `media_analyze_image` and `browser_analyze` cover local-image and current-page analysis. |
| `browser` | Present | Lemon exposes granular supervised browser actions rather than one multiplexed browser tool. |
| `computer` | Gap | Lemon's native surface controls browsers, not arbitrary desktop applications. |
| `checkpoint` / `rewind` | Present | Lemon's `checkpoint` supports list, diff, restore, and delete with audit events. |
| `task` / `ask` | Mostly present | Lemon has native tasks, delegated agents, `ask_parent`, and `parent_question`; a general channel-aware human clarification tool remains distinct. |
| memory and skills | Present | Lemon provides compact memory, topic memory, search, skill reads, and audited skill management. |

OMP references:

- [Builtin and hidden tool registry](https://github.com/can1357/oh-my-pi/blob/main/packages/coding-agent/src/tools/index.ts)
- [Edit-mode and per-model settings](https://github.com/can1357/oh-my-pi/blob/main/docs/settings.md)
- [Hashline patcher implementation](https://github.com/can1357/oh-my-pi/blob/main/packages/hashline/src/patcher.ts)
- [Write tool implementation](https://github.com/can1357/oh-my-pi/blob/main/packages/coding-agent/src/tools/write.ts)
- [LSP tool documentation](https://github.com/can1357/oh-my-pi/blob/main/docs/tools/lsp.md)

## Recommended Sequence

### 1. Unify the model-facing edit contract

Keep the existing implementations, but disclose one `edit` contract selected by model
profile or session configuration. Preserve explicit tool aliases for compatibility and
operator overrides. Measure tool-schema tokens, failed mutation calls, retry count, and
successful-edit latency before changing defaults.

### 2. Promote full LSP operations

Build a model-facing `lsp` tool on `LemonLsp.ServerManager` for definition,
type-definition, implementation, references, hover, document/workspace symbols, rename,
format, code-action listing/application, and a bounded raw-request escape hatch. Route
all workspace edits through the same checkpoint and mutation validation used by file
tools.

### 3. Add AST-aware search and staged edits

Start with a structured `ast_grep` query tool. Add `ast_edit` only with a proposal/apply
split, diff preview, checkpoint integration, generated-file protection, and explicit
language/parser availability reporting.

### 4. Add structured repository operations

`github` and `security_scan` should return bounded structured results and reuse Lemon's
approval, trust-fencing, checkpoint, and audit paths. Shell fallbacks remain valid for
uncommon operations.

### 5. Revisit write adapters

If Lemon needs OMP-like archive, SQLite-row, or privileged-broker writes, implement them
as explicit address schemes/adapters. Do not overload ordinary filesystem paths or
weaken the new local target checks. Generated-file protection should be the next small
write/edit safety addition.

## Validation Metrics

Use deterministic coding-agent evals to compare any edit-disclosure change:

- prompt and tool-schema tokens per turn;
- first-call edit success rate;
- mutation retries per completed task;
- stale-anchor and context-mismatch rate;
- partial-commit count and committed-prefix size;
- time from first mutation call to clean focused tests;
- accidental writes to generated, symlinked, or unintended paths.

Capability count alone is not the target. The goal is fewer ambiguous choices, safer
mutation semantics, and better first-attempt completion.
