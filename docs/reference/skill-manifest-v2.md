# Skill Manifest v2 Reference

Canonical schema for `SKILL.md` frontmatter. Both YAML (`---` delimiters)
and TOML (`+++` delimiters) are accepted.

> **Compatibility:** v1 skills (only the legacy fields) continue to parse
> without changes. v2 fields are optional; the platform supplies defaults
> where noted.

---

## Full example

```yaml
---
name: k8s-rollout
description: Use when managing Kubernetes deployments and rollouts.
version: "1.2.0"
author: acme-infra
tags:
  - kubernetes
  - devops
  - deployment

# v1 requires block (still valid)
requires:
  bins:
    - kubectl
    - helm
  config:
    - KUBECONFIG

# v2 fields
platforms:
  - linux
  - darwin

metadata:
  lemon:
    category: devops

requires_tools:
  - kubectl
  - helm

fallback_for_tools:
  - kube-ps1

required_environment_variables:
  - KUBECONFIG
  - KUBE_CONTEXT

verification:
  command: kubectl version --client
  expect_exit: 0

references:
  - path: examples/rollout.md
  - url: https://kubernetes.io/docs/concepts/workloads/controllers/deployment/
---
```

---

## Field reference

### Legacy v1 fields

| Field | Type | Required | Default | Description |
| --- | --- | --- | --- | --- |
| `name` | string | No | Directory name | Skill identifier used in CLI and registry. |
| `description` | string | **Yes** | `""` | Used for relevance matching. Keep under 200 chars. |
| `version` | string | No | — | Semantic version string. |
| `author` | string | No | — | Author or org name. |
| `tags` | list of strings | No | `[]` | Free-form tags for filtering. |
| `requires.bins` | list of strings | No | `[]` | Binaries checked with `which` at status-check time. |
| `requires.config` | list of strings | No | `[]` | Environment variables required at runtime. Promoted to `required_environment_variables` automatically. |

### v2 fields

| Field | Type | Default | Description |
| --- | --- | --- | --- |
| `platforms` | list of strings | `["any"]` | Platforms where this skill is applicable. Allowed values: `linux`, `darwin`, `win32`, `any`. Skills are hidden (not `not-ready`) on non-matching platforms. |
| `metadata.lemon.category` | string | — | Registry category path, e.g. `devops` or `languages/elixir`. |
| `requires_tools` | list of strings | `[]` | Semantic tool names required by this skill. Checked against installed tools at activation time. |
| `fallback_for_tools` | list of strings | `[]` | Tools this skill provides fallback guidance for when the tool is unavailable. |
| `required_environment_variables` | list of strings | Promoted from `requires.config` | Environment variables that must be set for the skill to be `ready`. Preferred over `requires.config` in v2 skills. |
| `verification` | map | — | Verification specification. See [Verification](#verification) below. |
| `references` | list | `[]` | Supplementary files or URLs. See [References](#references) below. |

### Verification

The `verification` map describes how to check that a skill's prerequisites are
actually working, beyond simple binary/env-var presence.

```yaml
verification:
  command: kubectl version --client  # shell command to run
  expect_exit: 0                     # expected exit code (default 0)
  expect_output: "Client Version"    # optional substring to check in stdout
```

| Key | Type | Description |
| --- | --- | --- |
| `command` | string | Shell command to run. |
| `expect_exit` | integer | Expected exit code. Defaults to `0`. |
| `expect_output` | string | Optional substring that must appear in stdout. |

### References

Each entry in `references` is either a plain string (treated as a local path)
or a map:

```yaml
references:
  - path: examples/rollout.md        # relative to skill root
  - url: https://example.com/docs    # external URL
  - path: schemas/config.json
    description: Configuration schema
```

| Key | Required | Description |
| --- | --- | --- |
| `path` | One of path/url | Relative path from the skill root directory. |
| `url` | One of path/url | Absolute URL. |
| `description` | No | Human-readable description of the reference. |

---

## Validation rules

1. `platforms` values must be one of `linux`, `darwin`, `win32`, `any`. Unknown values are rejected.
2. `requires_tools`, `fallback_for_tools`, `required_environment_variables` must be lists when present.
3. `verification` must be a map when present.
4. `references` entries must be strings or maps with at least a `path` or `url` key.
5. Legacy `requires.bins` and `requires.config` remain valid and are not deprecated.
6. `required_environment_variables` and `requires.config` may coexist; both are checked.

---

## Migration from v1

No changes are required to existing v1 skills. To opt into v2 features:

1. Replace `requires.config` with `required_environment_variables` (or keep both).
2. Add `platforms` if the skill is OS-specific.
3. Add `requires_tools` for semantic tool dependencies beyond raw binaries.
4. Add `references` to link supplementary files that `read_skill` can fetch on demand.

The manifest version is inferred automatically; there is no explicit version field.
