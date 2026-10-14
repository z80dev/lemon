# Secret obfuscation

Secret obfuscation keeps API keys, tokens and passwords out of the text Lemon
sends to model providers. When it is on, native coding sessions replace known
secrets in provider-visible messages with placeholders and put the real values
back into tool arguments before a tool runs. It is unrelated to the encrypted
secret store described in [secrets and keychain](secrets-and-keychain.md).

## Enabling

It is off by default. Turn it on in `~/.lemon/config.toml` or a project's
`.lemon/config.toml`:

```toml
[runtime.secret_obfuscation]
enabled = true
```

`LEMON_SECRET_OBFUSCATION_ENABLED=true|false` overrides the file setting. The
setting is read when a session starts.

## What is protected

Secrets are collected once when a session starts:

1. **Environment variables** whose name contains `KEY`, `SECRET`, `TOKEN`,
   `PASSWORD`, `PASS`, `AUTH`, `CREDENTIAL`, `PRIVATE` or `OAUTH` followed by
   `_` or the end of the name (case-insensitive), with a value of at least 8
   characters. `GITHUB_TOKEN` and `DB_PASSWORD_FILE` match; `AUTHOR` does not.
2. **`secrets.yml` entries** (see below).
3. **A built-in pattern** for GitHub (`ghp_`, `gho_`, `ghu_`, `ghs_`, `ghr_`,
   `github_pat_`), GitLab (`glpat-`), OpenAI (`sk-`, `sk-proj-`) and Anthropic
   (`sk-ant-`) style tokens that appear in session content or tool output.

Before every model call, Lemon rewrites an ephemeral copy of the conversation:
user text, assistant text and thinking, tool-call arguments, tool results,
shell output, custom messages and summaries. The session file and the
transcript you see keep the original text. Image data is not scanned. The
requests Lemon sends to summarize history for compaction, branch summaries and
project memory are rewritten the same way.

The system prompt is not scanned. Do not put secrets in `AGENTS.md`,
`CLAUDE.md` or other context files.

## Placeholders and restore

Obfuscated values become deterministic placeholders such as
`$$3P8W5JH1TK2Q$$`, `$$3P8W5JH1TK2Q:L$$` or
`$$GITHUBTOKEN_3P8W5JH1TK2Q:L$$`. When the model passes a placeholder in tool
arguments, Lemon restores the real value before the tool runs, including
inside nested arguments. Placeholders the model writes in ordinary assistant
text are shown as written.

The 12-character base is an HMAC of the exact secret under a private
per-install key in `<agent_dir>/secret-placeholder.key` (by default
`~/.lemon/agent/secret-placeholder.key`), created with mode `0600` when first
needed. The key is never sent to a provider, and its own bytes are redacted if
a tool reads the file. Because the key persists, a secret gets the same
placeholder in every session, which keeps provider prompt caches stable. If the
key cannot be written, Lemon logs a warning and uses a key that lasts only for
the current runtime process.

The optional suffix describes the casing of the hidden value's ASCII letters:

| Hint | Meaning |
| ---- | ------- |
| `:U` | all uppercase |
| `:L` | all lowercase |
| `:C` | first letter uppercase, the rest lowercase |
| `:M` | mixed casing |

Values that differ only in casing get unrelated bases.

## secrets.yml

| Level | Path |
| ----- | ---- |
| Global | `<agent_dir>/secrets.yml` (default `~/.lemon/agent/secrets.yml`) |
| Project | `<project>/.lemon/secrets.yml` |

The file is a YAML list. A project entry replaces a global entry with the same
`content`.

| Field | Type | Required | Description |
| ----- | ---- | -------- | ----------- |
| `type` | `plain` or `regex` | yes | Match a literal value or a pattern |
| `content` | string | yes | The secret value, or the regex pattern |
| `mode` | `obfuscate` or `replace` | no | Default `obfuscate` |
| `replacement` | string | no | Replacement text for `replace` mode |
| `flags` | string | no | Regex flags: `i`, `m`, `s`, `u` (`g` is implied) |
| `friendlyName` | string | no | Label added to `obfuscate` placeholders |

```yaml
# Reversible placeholder (default mode)
- type: plain
  content: sk-proj-abc123def456ghi789

# One-way replacement with a fixed string
- type: plain
  content: hunter2
  mode: replace
  replacement: "********"

# Labelled placeholder: $$GITHUBTOKEN_<base>:L$$
- type: plain
  content: github_pat_abc123def456
  friendlyName: GitHub Token

# Regex, with flags in a separate field or in /pattern/flags form
- type: regex
  content: "AKIA[0-9A-Z]{16}"
- type: regex
  content: "/bearer\\s+[a-z0-9._~+\\/=-]+/i"

# One-way replacement of every match; without `replacement`, each match is
# replaced by a same-length value the pattern does not match again
- type: regex
  content: "postgres://[^\\s]+"
  mode: replace
```

Modes:

| Mode | Result | Restored in tool arguments |
| ---- | ------ | -------------------------- |
| `obfuscate` | `$$BASE(:hint)$$` or `$$LABEL_BASE(:hint)$$` | yes |
| `replace` | `replacement`, or a deterministic same-length value | no |

`obfuscate` values and regex matches shorter than 8 characters are left alone,
so short words are not redacted. `replace` mode works on values of any length.

`friendlyName` is reduced to uppercase letters and digits and capped at 32
characters. It is dropped from a placeholder when it would reveal the secret it
labels or another configured secret, or when it matches a configured pattern.
On a regex entry the label applies to every match, so keep it general.

Patterns use PCRE syntax, which accepts common JavaScript-style patterns.

### Invalid entries

- A missing file means no entries.
- A file that cannot be parsed, or is not a list, is ignored with a warning.
- Invalid entries are skipped one by one with a warning: `type` must be
  `plain` or `regex`; `content` must be a non-empty string; `mode`,
  `replacement` and `flags` must have the types above; the pattern must
  compile; and a `replace` regex without `replacement` is rejected when it
  matches every possible 1–2 character value, because no stable redaction
  exists for it.
- An invalid `friendlyName` is dropped; the entry is kept.

## Order of matching

Each text is processed in this order: one-way replacements (including the
placeholder key), then literal `obfuscate` values, longest first, then regex
entries in file order with the built-in token pattern last. Placeholders
produced earlier in the pass are not rewritten by later steps.

## Implementation

`CodingAgent.Security.SecretObfuscator` builds the session obfuscator, runs as
a stage of the pre-LLM transform chain after the untrusted tool-output boundary,
and wraps session tools as the outermost wrapper (before extension hooks and
approval) to restore placeholders in tool arguments.
