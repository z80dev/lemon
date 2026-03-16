# Skills V2 — Progressive Loading and Manifest v2

This document describes the roadmap for the skills subsystem overhaul tracked
in milestones M2 and M3.

## Motivation

The current skill system inlines full skill bodies into every prompt.  As the
skills catalog grows this wastes context tokens and makes it harder to evaluate
which skills are actually relevant.

Skills V2 addresses this with two complementary changes:

1. **Manifest v2** — a richer, validated schema for skill metadata that supports
   partial reads (header only, description only, full body on demand).
2. **Progressive loading** — the runtime loads skill headers on startup and
   fetches the full body lazily when a skill is actually invoked.

## Feature flags

The rollout is split across two flags so each layer can be deployed
independently:

```toml
[features]
skill_manifest_v2            = "off"   # M2-01: new parser/validator
progressive_skill_loading_v2 = "off"   # M3-02/M3-03: lazy body loading
skills_hub_v2                = "off"   # combined gate for the full hub UX
```

## Milestone map

### M2 — Skill installer and registry

| Task | Description |
|---|---|
| M2-01 | Replace frontmatter parser with manifest v2 parser/validator |
| M2-02 | Expand `LemonSkills.Entry` and add lockfile storage |
| M2-03 | Introduce source abstraction and source router |
| M2-04 | Refactor installer and registry around inspect/fetch/provenance |
| M2-05 | Add legacy skill migration path |

### M3 — Progressive disclosure

| Task | Description |
|---|---|
| M3-01 | Create unified skill prompt view and activation logic |
| M3-02 | Stop inlining full skill bodies in prompts |
| M3-03 | Upgrade `read_skill` to structured partial loads |
| M3-04 | Add prompt/token regression tests for progressive disclosure |

## Backwards compatibility

All v1 skills parse without changes. v2 fields are optional; defaults are
applied automatically by `LemonSkills.Manifest.validate/1`. Legacy
`requires.config` entries are promoted to `required_environment_variables`
so callers can always use the v2 accessor.

## Manifest v2 schema (M2-01)

The parser is now split into two modules:

- `LemonSkills.Manifest.Parser` — low-level frontmatter extraction (YAML/TOML).
- `LemonSkills.Manifest.Validator` — semantic validation and default population.
- `LemonSkills.Manifest` — public API; delegates to Parser and Validator.

Full schema reference: [`docs/reference/skill-manifest-v2.md`](reference/skill-manifest-v2.md).

### New v2 fields

| Field | Type | Default | Purpose |
|---|---|---|---|
| `platforms` | `[string]` | `["any"]` | OS gate; hide incompatible skills |
| `metadata.lemon.category` | string | — | Registry browsing |
| `requires_tools` | `[string]` | `[]` | Semantic tool deps |
| `fallback_for_tools` | `[string]` | `[]` | Fallback guidance list |
| `required_environment_variables` | `[string]` | promoted from `requires.config` | Required env vars |
| `verification` | map | — | Check command/exit/output |
| `references` | `[string\|map]` | `[]` | Supplementary files for progressive loading |

### Usage

```elixir
{:ok, manifest, body} = LemonSkills.Manifest.parse(content)
{:ok, normalised}     = LemonSkills.Manifest.validate(manifest)

LemonSkills.Manifest.platforms(normalised)
# => ["linux", "darwin"]

LemonSkills.Manifest.required_environment_variables(normalised)
# => ["KUBECONFIG"]

LemonSkills.Manifest.version(normalised)
# => :v2
```
