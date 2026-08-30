# Changelog

All notable changes to `lemon_skills` are documented here.
The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/);
releases follow [Semantic Versioning](https://semver.org/) from `0.1.0` onward.

## [Unreleased]

First release as a standalone package. `lemon_skills` began inside the Lemon
umbrella and is published as part of the platform split (D14 in
`docs/platform-split.md`), after an API-stabilization pass: the modules other
applications actually call are documented with their real contracts, and the
modules nothing outside the package touches are marked internal.

### Added

- Dynamic official Hermes skill discovery and sparse import via
  `LemonSkills.Sources.Hermes`, `hermes:` installer identifiers, the
  `mix lemon.skill hermes` browser, and the control-plane catalog used by the
  terminal client's multi-select importer.

- `LemonSkills` — the facade: `list/1`, `list_by_category/1`, `get/2`,
  `refresh/1`, `find_relevant/2`, `status/2`, `install/2`, `update/2`,
  `uninstall/2`, `enable/2`, `disable/2`, `global_skills_dir/0`,
  `project_skills_dir/1`, `usage/2`, `usage_report/1`, `curate_skills/1`.
- `LemonSkills.Registry` — the GenServer cache behind the facade, plus
  `counts/0` and `search/2` (local results and online discovery in one call).
- `LemonSkills.Entry`, `LemonSkills.Manifest` (with `Manifest.Parser` and
  `Manifest.Validator`) — the `SKILL.md` bundle format: frontmatter or
  frontmatter-less markdown, declared binaries, environment variables and
  platforms, content and bundle hashes.
- `LemonSkills.Status` — readiness gating: missing binaries, missing
  configuration, missing environment variables, platform compatibility.
- `LemonSkills.Installer`, `LemonSkills.SourceRouter` and the
  `LemonSkills.Source` behaviour with its six implementations
  (`Sources.Builtin`, `Sources.Local`, `Sources.Git`, `Sources.Github`,
  `Sources.Hermes`, `Sources.Registry`) — install from a directory, a git
  remote, GitHub, the official Hermes catalog, or the skill registry, each
  carrying a trust level.
- `LemonSkills.TrustPolicy` — which trust levels require an audit and which
  auto-approve.
- `LemonSkills.Audit.Engine`, `LemonSkills.Audit.BundleAudit`,
  `LemonSkills.Audit.LlmReviewer` and `LemonSkills.Audit.Finding` — a
  deterministic content scan over the whole bundle plus an optional model
  review, combined into one `:pass`/`:warn`/`:block` verdict cached against a
  fingerprint of both the content and the audit configuration. A `:block`
  fails the install; a `:warn` requires explicit approval.
- `LemonSkills.Discovery` — online skill discovery by GitHub topic search.
- `LemonSkills.McpSource` — MCP servers as a runtime tool source, configured
  through `LEMON_MCP_SERVERS` / `config :lemon_skills, :mcp_servers`, with
  stdio, HTTP and SSE transports and a five-minute tool cache.
- `LemonSkills.Tools.*` — the twelve assistant-facing tools an agent loop can
  mount: `read_skill`, `skill_manage`, `memory`, `memory_topic`,
  `search_memory`, `kanban`, `media_status`, `media_generate_image`,
  `media_generate_speech`, `media_generate_video`, `media_analyze_image`,
  `media_transcribe_audio`.
- `LemonSkills.Curator` and `LemonSkills.Synthesis.Pipeline` — usage-driven
  curation of installed skills, and drafting of new ones from an agent's own
  history.
- `LemonSkills.Usage` — persisted per-skill load/write counters and pinned or
  archived state.
- `LemonSkills.BuiltinSeeder` and `LemonSkills.Migrator` — seed the skills
  bundled in `priv/builtin_skills/` into the user's global skills directory,
  never overwriting anything already there.
- `LemonSkills.HttpClient` — the injectable HTTP behaviour every remote source
  fetches through (`config :lemon_skills, :http_client`).
- `LemonSkills.Env` — the environment variables this package declares,
  aggregated by `LemonCore.Env`.
- `mix lemon.skill` and `mix lemon.skill.lint` for managing and linting skills
  from the shell.

### Changed

- Avoid unnecessary full-list traversal when validating official Hermes skill
  identifiers.

- YAML skill frontmatter now uses `YamlElixir`, enabling nested objects and
  flow lists used by Hermes manifests. Hermes platform and prerequisite aliases
  normalize to Lemon's canonical readiness fields.

- API-stabilization pass ahead of the first release. Every module an
  application outside this package calls now documents its real contract —
  including options, defaults and error terms — and the modules that are pure
  implementation detail (`Bundle`, `Lockfile`, `InstallPlan`, `PathBoundary`,
  `Audit.State`, `Audit.SkillLint`, and the `Synthesis` draft internals) are
  `@moduledoc false`. No function was renamed, removed, or given a different
  return shape: this release documents the surface as it is so that later
  changes to it are visible as semver events.
- The package declares an Elixir floor of `~> 1.15`, matching the rest of the
  published Lemon packages (it previously tracked the umbrella's `~> 1.19`).

### Known rough edges

Documented as they behave today; changing them is a `0.2.0` question because
each one is a breaking change for a caller:

- Return shapes are not uniform. `LemonSkills.get/2` answers `{:ok, entry}` or
  a bare `:error`, while `install/2` answers `{:ok, entry}` or
  `{:error, reason}`. `Registry.list/1` returns a list but `Registry.search/2`
  returns `%{local: [...], online: [...]}`.
- Tool callbacks are not uniform either: most `LemonSkills.Tools` modules
  always return an `AgentToolResult`, but `kanban` and a few others may return
  `{:error, message}` instead of a result carrying `is_error: true`.
- `Audit.BundleAudit.audit_status/1` raises on a map that is not an audit
  record, while `audit_findings/1` answers `[]` for the same input. Audit
  records are string-keyed maps rather than a struct, so their keys are public
  API by accident rather than by declaration.
- `BuiltinSeeder.seed!/1` carries a bang but never raises — it logs and
  returns `:ok`, because a skill that cannot be seeded must not stop the
  application from booting.
- `McpSource.discover_tools/1` returns `[]` both when MCP is disabled and when
  it is enabled but found nothing; callers that need to tell those apart have
  to consult `mcp_enabled?/0` or `status/0`.
- `LemonSkills.Config` is a 31-function grab bag of path resolution, per-skill
  enable/disable state, and MCP server configuration. Those are three
  concerns, and splitting them is the main API change on the table for `0.2.0`.
- A few facade names differ from the functions they delegate to
  (`status/2` → `Status.check/2`, `usage/2` → `Usage.get/2`,
  `curate_skills/1` → `Curator.run/1`).
