# Agent Safety Contract

Lemon agent safety is layered. No single check is the boundary; tool exposure,
approvals, memory screening, skill audits, and telemetry each cover a different
failure mode.

## Tool Exposure

`CodingAgent.ToolPolicy` is the first boundary. Tool-policy profiles decide which
tools are available, which are blocked, and which require approval.

- `:full_access` is for trusted local coding work.
- `:orchestrator` keeps delegation tools for parent sessions.
- `:leaf_worker` keeps normal work tools but removes delegation (`task`,
  `agent`, `goal`, `kanban`, `cron`, `peer`). It keeps `agent_message` for
  its own task family only (see below).
- `:read_only` allows the read-tool list; `:safe_mode` allows only tools that
  are neither dangerous nor delegating.
- `:subagent_restricted` is `:safe_mode` plus approval for `write` and `edit`;
  `:no_external` allows only tools without external reach. `peer`
  sends session content to remote A2A agents, so it is dangerous, external
  and delegating.
- `:minimal_core` is a curated tool allowlist, not a read-only or side-effect-free
  profile. It includes file writes, shell execution, and browser tools.

Every restricted profile is an allow list over `LemonCore.ToolCatalog`, which
classifies each platform tool's approval tier and its `:dangerous`,
`:external` and `:delegation` capabilities. Restricted profiles fail closed: a
tool the catalogue does not classify is denied. That includes satellite tools
registered through `LemonAgent.ToolRegistry` (`omp`, `cua_js`, `cua_js_reset`,
`honcho_*`) and every MCP, extension and WASM tool; full-access, orchestrator
and custom policies grant them by name. A new built-in tool must be added to
the catalogue to appear in a restricted profile. Satellites cannot register a
catalogued name, and a WASM, extension or MCP tool that uses one is dropped, so
no contribution inherits a platform tool's classification. Tool policy is not
operating-system isolation, and invalid custom policies and unknown profiles
still need their own validation.

`omp` runs its own tools under its own approval mode, so it is bounded by the
caller's effective policy: `yolo` requires unreviewed `bash`, `write` and
`edit`, `write` requires unreviewed `write` and `edit`, an omitted mode is
pinned to that ceiling, and below `yolo` the cwd must resolve (symlinks
included) inside the session cwd or workspace directory. A missing policy or one
that does not grant `omp` refuses every action. omp cannot enforce
`allowed_commands`/`blocked_commands`, so either list refuses delegation.
`send` re-checks a live worker's recorded approval mode (an omitted one counts
as `yolo`) and workspace against the caller's current policy and refuses a
worker that now exceeds it.

`agent_message` carries the `:family_messaging` class, not `:delegation`:
bare names and `agent://` reach the caller's own task family, as
`write agent://…` does. While a policy does not grant every `:delegation`
tool (`LemonCore.ToolPolicy.family_messaging_only?/1`), the tool refuses named
targets (`@handle`, `session://`, `bot://`), named listing, `rename` and
`status`. Restricted profiles and read-only personas (scout, reviewer, seance)
therefore keep family messaging without external reach.

Tool disclosure hides long-tail tools behind `tool_search` and `tool_invoke`.
The bridges pass the same approval gate as every other tool, and disclosure
activates only when the policy admits both; otherwise every permitted tool is
disclosed directly. `tool_invoke` is a `:read`-tier dispatcher because each
hidden target keeps its own policy check and approval gate.

## Approvals

`LemonCore.ExecApprovals` is the human/admin gate for sensitive actions.
Approvals may be one-shot, session-scoped, agent-scoped, or global; existing
node-scoped policy can also satisfy a request. Denials are explicit and must
be respected by callers.

`CodingAgent.ToolExecutor` executes a gated tool only after an explicit approved
response with a supported scope. Approval request exceptions, exits, throws,
malformed replies, and unsupported scopes fail closed. An unavailable approval
service never produces automatic authorization. Raw service error terms are
excluded from tool results and logs; callers receive bounded error categories.
The failure boundary covers the approval request only, so exceptions raised by
an approved tool are not reclassified as authorization failures.

Use approval gates when a tool can mutate files, execute commands, install
code, call external systems with side effects, or change local trust state. Do
not use approval prompts as a substitute for removing a tool from a restricted
profile. A supported approval authorizes that invocation; it is not an
exactly-once guarantee for external effects or a process-crash recovery policy.

### Lemon Bot remembered approvals

**Standard** access enables Terminal and Files but asks before commands. **Chat
only** does not grant those capabilities. An access request changes what a Bot
may use; approving it does not approve the command that follows.

On an eligible approval card, **Allow once** approves that invocation.
**Allow Terminal for this chat** (or the corresponding file-reading or
file-change option) remembers a **tool group**, not the exact command shown:

| Scope | Applies to | How to end it |
| --- | --- | --- |
| Per-chat | The owner's chat, Bot and current execution context only | Use **Stop allowing**, or change the applicable access/review policy |
| Bot-wide | Eligible owner chats, routines and native follow-ups for that Bot | Return its approval review setting to per-chat/every-time, or revoke the allowance |

Bot-wide approval requires an explicit preview/confirmation in Bot settings;
an approval card cannot silently create it. It is broader than “this chat.”
Allowance use is audited and rechecks current policy and placement bindings.
Changed permissions, placement or governance can invalidate an allowance;
it never creates access that the Bot, machine or owner lacks.

Workspace governance sets `rememberedApprovals`:

- `off`: no remembered approvals.
- `chat` (default): eligible per-chat allowances only.
- `chat_and_bot`: also permits explicitly confirmed Bot-wide allowances.

Only native Terminal (`bash`, `bash_output`, `kill_process`), file changes
(`write`, `edit`, `patch`, `ast_grep`, `checkpoint`) and file reading
(`read`, `ls`, `find`, `grep`) groups are eligible, subject to effective policy.
Required or personal ask-first rules can remove eligibility.

Never eligible: product access/permission requests, external-message sends,
purchases, connector changes, other tools outside those groups, or approvals
marked as requiring a human. External-channel runs cannot use these allowances.
Routines and native follow-ups cannot borrow per-chat allowances; only an
eligible Bot-wide allowance can cover them. Remembering Terminal is powerful:
it is not a sandbox or a guarantee about what a shell command will do.

### Bot folder reads and the egress fence

Each Bot has a destination-local folder, separate from its workspace metadata.
With effective Files read access and an enabled folder-read exemption, native
`read`, `ls` and `grep` may read that folder without individual review.
`folderReadsNeedReview`, explicit Files review rules and a restrictive effective
policy can disable the exemption.

The runtime derives the canonical folder from the Bot profile; an arbitrary cwd
does not qualify. Targets must stay inside it after symlink resolution; internal
URLs and hard-linked `read` targets do not qualify. `grep` needs non-following
ripgrep support. `find`, writes, shell commands and reads outside the folder are
not exempt.

Before an exempt read succeeds, Lemon durably fences that session:
`webfetch` and `websearch` require approval for the rest of the session.
The fence survives session restore and is inherited by task/subagent children.
If it cannot be persisted, the read needs review instead. This is a targeted
tool-level egress control, **not** an operating-system network sandbox or a
promise that approved shell commands cannot send data.

### macOS permissions

On app-managed local workers, macOS privacy permissions (TCC) are attributed to
the embedded **Lemon Bot Worker** helper. Open the local machine's **Permissions**
pane to inspect grants, explicitly request Screen Recording or Accessibility,
or open System Settings for Full Disk Access and Files & Folders. Status probes
do not prompt. Desktop/Documents/Downloads may prompt on first access.

Older unwrapped workers attribute grants to the runtime's `erlexec`, which can
lose that identity on update; **Use Lemon Bot Worker** switches the managed
worker to the helper. The helper is **not a sandbox**: every Bot and subprocess
running through that worker can use its OS grants. Grant only what you intend,
and revoke it in System Settings → Privacy & Security. Product access and human
approvals still apply independently. Desktop-control tools may also need their
own installed dependencies, such as Peekaboo.

## Operator State

Model-driven file mutations never write Lemon operator state
(`CodingAgent.Tools.OperatorState`). `write` (including archive and SQLite
members), `edit` (text and anchored), `patch`, `ast_grep` rewrites, LSP
workspace edits, ACP-client writes/deletes/renames, `fs_checkpoint` restore,
browser downloads/screenshots/analysis captures (default directories included)
and media artifacts (image, speech, video, transcription, analysis) refuse a
target whose lexical or canonical path (symlinks resolved, compared
case-insensitively) is an ancestor of a protected root, lies in an explicit
root, or lies in a broad root outside a work area. An existing file with more
than one hard link is refused too.

- Broad roots: the Lemon home state directory (`~/.lemon`: `config.toml`, the
  secrets master key and store, trust and skill-audit records, extensions,
  skills, `cron_memory`, kanban controller repos, execution-node credentials,
  managed installs) and the agent directory (`LEMON_AGENT_DIR`).
- Explicit roots, which work areas never reopen: the global config, secrets key
  file, store, dotenv file, checkpoint directory and `LEMON_BOT_DATA_DIR`
  wherever they are configured; every operator-configured extension source
  root (`[runtime] extension_paths`) and the global extensions directory; and
  toolchain locations Lemon executes from: `~/.local/bin`, `~/bin`, and for
  `[runtime] git_path` (or the trusted system `git`) and every post-edit checker
  or formatter found on `PATH`, the executable as found, its directory, its
  resolved symlink target and that target's directory.

The model's work areas stay writable: the assistant workspace, profile
workspaces and bot folders, and kanban worker worktrees (inside an assistant
workspace, `.lemon/skill(s)`, `.lemon/extensions` and `.lemon/config.toml` stay
protected). Lemon's own writers get narrow grants that keep the hard-link
refusal: a cron run may update only its exact `cron_memory/<job>.md`, the plan
writer only direct children of its session plan directory, and
`write local://…`/`report_issue` only the session's own scratch files. Media
artifacts are written to a temporary file renamed into place, so an existing
symlink or hard link at the name is replaced rather than written through.
`remember` refuses hard-linked preference files. `skill_manage` with
`scope: "global"` (skills in the agent directory) always needs a human approval,
whatever `[skills] write_approval` says, and is refused without an interactive
approver. There is no other override: the operator edits these files directly.

`bash`, `eval` and `process_input` are not confined. As a best-effort check, a
call whose text (command, code, input, `cwd`, `env` values, with `~`, `$HOME`
and `${HOME}` expanded) names a protected root (a toolchain directory only when
it is writable) or a `.lemon` path component, or that runs in the state or agent
directory outside a work area (inside one, when its text contains `..`), needs
a one-time human approval (`once_only`: no stored or wildcard grant applies)
under every approval mode, `yolo` included. Commands that build paths at run
time are not detected; approve shell access only where that risk is acceptable.

## Durable Memory

The run-history search index stores summaries rather than complete transcripts.
`LemonMemory.Ingest` builds `LemonMemory.Document` records after run finalization.
When the feature flag enables session search, the default `LemonMemory.Store`
setting routes ingest writes through `LemonMemory.Providers` to the configured
provider chain.
Session transcript persistence is a separate surface.

Before a document is stored or mined for skill synthesis,
`LemonMemory.Safety` screens `prompt_summary` and `answer_summary` for
secret-looking content such as password assignments, API keys, private-key
headers, and JWT-like tokens. Matching run-derived documents are skipped rather than
redacted in place.

Reviewed source learning follows a separate explicit-confirmation path through
`LemonSkills.Learn`. It binds confirmation to the exact source and destination
state, redacts confirmed content again at the durable boundary, and writes a
memory document plus an audited skill draft. This path does not rely on the
run-ingest feature flag.

`recall` is read-only search over past conversation summaries and longer notes.
`remember` explicitly adds, replaces, or removes compact facts in `USER.md` or
`MEMORY.md`. Procedural workflows belong in audited skills.

## Skills

Skill reads and writes have different trust boundaries:

- `read_skill` is read-only and emits redacted load telemetry.
- `skill_manage` writes project or global skills and runs audit checks.
- Installer flows use `LemonCore.ExecApprovals` for install/update/uninstall
  unless ordinary approval is pre-authorized or configured off.
- `LemonSkills.Audit.Engine` scans auditable bundle files.
- `LemonSkills.Audit.BundleAudit` caches results by bundle hash and audit
  fingerprint.
- `:warn` verdicts require approval unless explicitly pre-authorized through
  the installer's `:approve` option.
- `:block` verdicts require a separate exact-bundle security-override approval;
  the ordinary `:approve` option cannot bypass a block. Denial, timeout, or an
  unavailable approval service refuses the operation.

Auditable bundles include `SKILL.md` plus supported files under `references/`,
`templates/`, `scripts/`, and `assets/`. Symlinked bundle entries are rejected
so audits cannot escape the skill root.

## Observability

Safety-relevant operations must emit enough metadata to audit behavior without
recording sensitive payloads:

- tool/session provenance for tool calls and tool results
- redacted skill load/write telemetry
- missed-skill and missed-learning observations
- approval request and resolution events
- memory search and durable topic creation traces

Telemetry should identify the operation, actor, run/session, and outcome. It
must not include skill bodies, patch payloads, command secrets, or memory
contents that were rejected by safety screening.

## Change Checklist

When adding or changing an agent capability:

1. Classify the tool in `CodingAgent.ToolPolicy`.
2. Add approval gates for side effects that remain available to trusted profiles.
3. Validate user or model-provided structured arguments before side effects.
4. Keep durable memory writes behind `LemonMemory.Safety`.
5. Route reusable procedural knowledge through audited skills.
6. Emit redacted telemetry with run/session provenance.
7. Add focused deterministic tests and, when model behavior matters, an opt-in
   live-model eval. Approval tests must cover exceptions, exits, throws, invalid
   responses, denied decisions, timeouts, and valid approvals.

The September review covers dispatch and approval failure semantics; it is not
an exhaustive security audit of every tool, skill source, or storage backend.

*Last reviewed: 2026-11-11*
