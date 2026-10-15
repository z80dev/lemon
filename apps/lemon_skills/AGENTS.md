# LemonSkills contributor guide

Skills owns skill discovery/install/audit/curation and assistant-platform tools.
Coding-session/file tools belong in `coding_agent`. Usage lives in the
[user guide](../../docs/user-guide/skills.md); schemas and integration details in
[skills reference](../../docs/skills.md) and
[manifest reference](../../docs/reference/skill-manifest-v2.md).

## Registry and manifests

- Skills are `SKILL.md` bundles, not compiled tools. Keep manifest keys strings;
  YAML uses `YamlElixir`, TOML the existing supported subset. Normalize external
  platform/prerequisite aliases at the manifest boundary.
- Name/description and metadata lists are bounded valid single-line UTF-8 with
  no control/bidi characters. Missing legacy fields may use registry defaults;
  malformed present fields must not become prompt instructions.
- Project skills override global collisions. Listings and relevance ties are
  deterministic by key so prompt bytes remain stable.
- Registry search snapshots contain bounded body excerpts and content identities.
  Hash scans run outside the GenServer; same-size edits must invalidate caches.
  Requirements/provenance use current PATH/env/disabled state at read time.
- Prompt metadata is flattened, bounded and escaped with explicit source/trust
  labels. Community/project/local metadata is relevance data, not authority.
- Builtin seeding and forced `LemonSkills.refresh/1` remain the existing discovery
  path. Do not add another registry or profile-local skill database.

## Install and learning safety

- Every non-builtin install/update audits the complete supported bundle file set.
  Reject symlink escapes. Cache audit results only for identical bundle hash and
  audit fingerprint; detailed audit/usage state stays outside `SKILL.md`.
- Ordinary approval does not bypass a block. Warn requires explicit approval;
  block requires the distinct operation security override bound to exact hash and
  findings. Non-interactive `approve: true` is not that override. Re-audit changed
  bytes and the staged copy before activation.
- Official Hermes IDs go through `Installer` and source routing, not direct copies
  into the registry. Official source is provenance, not permission to skip audit.
- Portable skill/automation blueprints are owned by `LemonAutomation.Blueprint`.
  Reuse bundle, manifest, lint/audit and profile services; no second scheduler.
- `LemonSkills.Learn` composes bounded `LemonCore.Context`, memory and synthesis
  drafts. Review is non-mutating/content-free; confirmation re-resolves sources,
  recomputes conflicts and requires the exact fresh digest. Never execute source
  content or create a separate learning database.
- Usage/curation sidecars track provenance, counters and lifecycle. Pinned skills
  cannot be archived/deleted until unpinned; archived skills stop surfacing through
  existing disabled-skill config.

## Tool seams

- Use `AgentTool` / `AgentToolResult` and the existing registry. Label data-bearing
  results untrusted; the coding-session boundary applies fencing before the model.
- `remember(text, target, replaces)` edits assistant workspace `USER.md`/`MEMORY.md`.
  `recall(query, scope, limit)` searches scoped historical runs and workspace
  `memory/*.md` notes. Do not restore removed overlapping memory tools or conflate
  these tools with the lower-level `SessionSearch` feature/config name.
- Remember selectors prefer an exact whole entry, otherwise require a unique
  substring; patches change only that span and deletion removes the whole entry.
- Prompt memory capacity labels report full store usage, not the bounded excerpt.
  Capacity errors measure attempted text separately from file-format overhead.
- Media work uses `lemon_media`; browser/LSP drivers own their supervised sessions.
  Keep public artifacts/errors bounded and redacted.
- `McpSource` consumes external stdio/HTTP/SSE MCP services through supervised
  clients. Model-facing names are namespaced; raw remote names stay inside the
  client boundary. Preserve exact filters, capability gating, redacted sampling
  review and credential isolation. Do not add a server surface here.
- Independent A2A peers use core client/store contracts; configured credentials
  are secret references and remote content is untrusted.

## Configuration and verification

Global agent directory resolution is `LEMON_AGENT_DIR`, skills app env, coding
agent app env, then `~/.lemon/agent`. The harness-compatible global skills path
is `~/.agents/skills`; tests/isolated runtimes can set `LEMON_HARNESS_SKILLS_DIR`.
Keep those shared locations aligned without copying configuration systems.

From the umbrella root: `mix test apps/lemon_skills/test`.
Use injected `HttpClient` and temporary skill roots. Restore env/registry state.
Exercise traversal/symlinks, changed-content approvals, scope precedence,
deterministic search, stale confirmations and disabled/archive behavior.
