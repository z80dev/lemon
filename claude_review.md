# PR Review: `feat/milestone-m0-m8-implementation`

**Branch:** `feat/milestone-m0-m8-implementation`
**Base:** `main`
**Scope:** 168 files | +22,351 / -4,019 | 1 commit (`f5886fd3`)
**Reviewed:** 2026-03-16

---

## Summary

| Severity | Count |
|----------|-------|
| Critical | 11 |
| Major | 23 |
| Minor | 35 |
| Nit | 15 |
| **Total** | **84** |

Five review domains were covered in parallel:

1. **Core Runtime** — boot, env, health, profile, setup, doctor, update
2. **Memory System** — store, ingest, document, search, features
3. **Skills System** — sources, manifest v2, lockfile, audit, synthesis, trust
4. **Adaptive Behavior** — rollout gates, routing feedback, outcomes, fingerprint, model selection
5. **CI/CD & Infrastructure** — workflows, docs, release, config, README

---

## Critical (11)

### C1. Broken adaptive model selection — toolset mismatch renders history lookup inert

**`apps/lemon_router/lib/lemon_router/run_orchestrator.ex:568-569`**

When building the `TaskFingerprint` for history lookup, the `toolset` field defaults to `[]`, producing a context key like `code|-|/home/user/proj`. But when feedback is *recorded*, the fingerprint includes actual tools like `bash,read_file`. The `best_model_for_context` LIKE query (`code|-|/home/user/proj|%`) will never match a recorded key like `code|bash,read_file|/home/user/proj|anthropic|opus`.

**Impact:** History-based model selection is entirely non-functional — the feature gate may pass, but it will never return a model.

**Fix:** Pass the actual toolset when building the fingerprint for history lookup, or change the query to ignore the toolset segment.

---

### C2. Duplicate and divergent rollout gate modules

**`apps/lemon_core/lib/lemon_core/rollout_gate.ex` vs `apps/lemon_core/lib/lemon_core/rollout_gates.ex`**

`RolloutGate` (singular) and `RolloutGates` (plural) both evaluate routing feedback and synthesis readiness, but with completely different thresholds and APIs:

- `RolloutGate`: min_samples=50, uses success_delta (+5pp) and retry_delta comparisons, takes a flat metrics map
- `RolloutGates`: min_sample_size=20, uses aggregate success_rate (>=0.60) and failure_rate (<=0.20), takes store_stats + fingerprint list

They can produce contradictory results for the same data. It's unclear which is canonical or whether both are meant to coexist.

**Impact:** If the wrong one is wired into the promotion path, features could graduate prematurely or be blocked forever.

**Fix:** Pick one module as canonical, delete or deprecate the other, and ensure all callers use the same thresholds.

---

### C3. Release startup crash in `Profile.default_name/0`

**`apps/lemon_core/lib/lemon_core/runtime/profile.ex:105-106`**

The `rescue ArgumentError` is intended to catch `String.to_existing_atom/1` failure, but `Mix.env()` (line 97) raises `UndefinedFunctionError` in a release (Mix not available). The rescue won't catch it.

**Impact:** When `LEMON_RUNTIME_PROFILE` is not set in a release, this is a hard crash on startup.

**Fix:** Rescue `UndefinedFunctionError` as well, or check for Mix availability first with `Code.ensure_loaded?(Mix)`.

---

### C4. Hardcoded dev cookie as production fallback

**`apps/lemon_core/lib/lemon_core/runtime/env.ex:35,122`**

`node_cookie` defaults to `"lemon_gateway_dev_cookie"`. If deployed without `LEMON_GATEWAY_NODE_COOKIE` set, any node knowing this publicly-visible string can connect to the Erlang cluster.

**Impact:** Cluster-level security hole in production deployments.

**Fix:** Refuse to start in `:prod` without an explicit cookie, or at minimum log a loud warning. Generate a random cookie if none is set.

---

### C5. `System.halt(1)` bypasses OTP shutdown

**`apps/lemon_core/lib/lemon_core/runtime/boot.ex:92`**

`System.halt(1)` kills the VM immediately without running shutdown callbacks, supervisor cleanup, or flushing logs.

**Impact:** Dirty shutdown can corrupt state, lose buffered telemetry/logs, and leave child processes orphaned.

**Fix:** Use `System.stop(1)` for graceful shutdown, or propagate the error to the caller.

---

### C6. Trailing space in GitHub auth header

**`apps/lemon_skills/lib/lemon_skills/sources/github.ex:103`**

```elixir
[{"Authorization", "token #{token} "} | build_headers(nil)]
```

Trailing space after the token. GitHub's API may reject or misinterpret this.

**Impact:** Silent auth failure — requests fall back to unauthenticated (rate-limited) without any error surfaced to the user.

**Fix:** Remove the trailing space: `"token #{token}"`.

---

### C7. `String.to_existing_atom/1` crash on corrupted lockfile

**`apps/lemon_skills/lib/lemon_skills/entry.ex:271`**

```elixir
defp parse_atom(s) when is_binary(s), do: String.to_existing_atom(s)
```

If a lockfile contains a trust_level or source string that doesn't correspond to an already-loaded atom, this raises `ArgumentError` and crashes the entire lockfile load.

**Impact:** A corrupted or hand-edited lockfile kills all skill loading.

**Fix:** Use an allowlist of valid atoms, or `String.to_atom/1` with explicit validation against known values.

---

### C8. Uninstall confirmation bypass — control flow bug

**`apps/lemon_skills/lib/mix/tasks/lemon.skill.ex:346-351`**

```elixir
unless confirmed do
  Mix.shell().info("Cancelled.")
end
# ... uninstall proceeds regardless
```

The `unless` block prints "Cancelled." but does NOT return early or halt execution. The uninstall continues whether the user confirms or not.

**Impact:** Users cannot cancel a skill uninstall once prompted.

**Fix:** Wrap the uninstall logic in `if confirmed do ... else Mix.shell().info("Cancelled.") end`.

---

### C9. Placeholder security contact email

**`SECURITY.md:11`**

```
Email: security@lemon (replace with actual contact when available)
```

**Impact:** Non-functional. Anyone finding a vulnerability has no way to privately report it. Must be replaced before the repo goes public.

**Fix:** Replace with a working email address, or enable GitHub's private vulnerability reporting feature.

---

### C10. Example config ships insecure default

**`examples/config.example.toml:43`**

`dangerously_skip_permissions = true` is enabled by default in the example config.

**Impact:** Users copying this file will have an insecure configuration.

**Fix:** Set to `false` or comment it out with a clear warning.

---

### C11. Example config encourages plaintext API keys

**`examples/config.example.toml:1-2`**

The example uses `api_key = "sk-ant-your-api-key-here"` (plaintext in config) while the README and setup guide correctly show `api_key_secret = "llm_anthropic_api_key"` (encrypted keychain reference). Directly contradicts the security design described in `SECURITY.md:40`.

**Fix:** Use the `api_key_secret` pattern and note that `api_key` is supported but discouraged.

---

## Major (23)

### J1. LIKE wildcard injection in `best_model_for_context`

**`apps/lemon_core/lib/lemon_core/routing_feedback_store.ex:108`**

The SQL `WHERE fingerprint_key LIKE ?1 || '|%'` uses the context key as a LIKE pattern prefix. The context key includes `workspace_key` which is a filesystem path. Paths containing `%` or `_` (e.g., `/tmp/test_dir`, `/home/user/100%_done`) will be interpreted as LIKE wildcards, matching unrelated fingerprints.

**Fix:** Use SQLite's `ESCAPE` clause, switch to `glob`, or use `>=` / `<` range comparison for prefix matching.

---

### J2. Inflated failure rate in `RolloutGates.aggregate_outcomes`

**`apps/lemon_core/lib/lemon_core/rollout_gates.ex:252`**

`fp_failure = fp_total - fp_success` counts all non-success outcomes (`:partial`, `:aborted`, `:unknown`) as failures. These are not failures by `RunOutcome` semantics.

**Impact:** A run with 60% success, 20% partial, 20% aborted would report 40% failure rate and fail the gate, even with zero actual failures.

**Fix:** Explicitly count only `:failure` outcomes, or categorize `:partial`/`:aborted` separately.

---

### J3. UTF-8 truncation produces invalid strings

**`apps/lemon_core/lib/lemon_core/memory_document.ex:165-167`**

`binary_part(text, 0, @max_summary_bytes)` slices at a raw byte boundary. If a multi-byte UTF-8 codepoint straddles byte 2000, this produces an invalid UTF-8 binary. This corrupted string then goes into SQLite and FTS5.

**Impact:** Indexing errors or garbled display for any document with multi-byte characters near the truncation point.

**Fix:** Use `String.slice/2` (codepoint-aware) or scan backward to find a valid UTF-8 boundary.

---

### J4. SearchMemory tool silently broadens scope to `:all`

**`apps/coding_agent/lib/coding_agent/tools/search_memory.ex:38-58, 101-103`**

The tool's JSON schema exposes `scope` with `"agent"` and `"workspace"` options, but there is no `scope_key` parameter in the schema. `resolve_scope_key/3` reads `params["scope_key"]` which is always `nil`. A `nil` scope_key fails the guard in `MemoryStore.do_search` and falls through to `search_all`.

**Impact:** Data isolation violation — selecting scope "agent" or "workspace" silently searches the entire store.

**Fix:** Add `scope_key` to the tool parameter schema, or auto-derive it from session context.

---

### J5. FTS and main table inserts are not atomic

**`apps/lemon_core/lib/lemon_core/memory_store.ex:646-657`**

`do_put` inserts into `memory_documents` first, then into `memory_fts`. If the FTS insert fails (`:busy`, schema error, corrupt data from J3), the main table row persists but FTS doesn't index it. No transaction wrapping, no compensating rollback.

**Impact:** Documents exist but are invisible to search.

**Fix:** Wrap both inserts in `BEGIN IMMEDIATE ... COMMIT`, or log a warning and compensating-delete the main row on FTS failure.

---

### J6. Feature flag config loaded 4 times per ingest

**`apps/lemon_core/lib/lemon_core/memory_ingest.ex:47, 72, 76, 117-132`**

`ingest/3` calls `session_search_enabled?()` and `routing_feedback_enabled?()` before casting, and `handle_cast` calls them again. Each call invokes `LemonCore.Config.Modular.load()` which likely hits disk.

**Impact:** 4 disk reads per ingested document. Performance bottleneck under steady ingest load.

**Fix:** Read the config once in `handle_cast`, pass the flags down, remove the double-check in `ingest/3`.

---

### J7. Socket leak in `Health.probe/3`

**`apps/lemon_core/lib/lemon_core/runtime/health.ex:127-135`**

The `with` block opens a TCP socket, but if `:gen_tcp.send/2` or `recv_response/2` fails, the `else` clause returns `{:error, :unreachable}` without closing the socket. Only the happy path closes the socket.

**Fix:** Wrap in `try/after` to ensure socket is always closed.

---

### J8. `async: true` env tests mutate global state

**`apps/lemon_core/test/lemon_core/runtime/env_test.exs:2`**

The test is marked `async: true` but calls `System.put_env`/`System.delete_env`, which are global mutations. Parallel test runs can interfere with each other.

**Fix:** Change to `async: false`.

---

### J9. `String.to_atom/1` on user-provided profile name in wizard

**`apps/lemon_core/lib/lemon_core/setup/wizard.ex:226, 234`**

User-provided profile name string is converted via `String.to_atom(choice)`. Atoms are never GC'd.

**Impact:** Atom table exhaustion vector in an interactive wizard.

**Fix:** Use `String.to_existing_atom/1` with a rescue, or validate against a known allowlist.

---

### J10. `Provider.maybe_bootstrap_config` swallows scaffold errors

**`apps/lemon_core/lib/lemon_core/setup/provider.ex:50-63`**

When `Scaffold.bootstrap_global()` returns `{:error, reason}`, the `unless` block evaluates to `nil`, and the trailing `:ok` on line 63 is returned. The `with` chain in `run/2` never sees the failure.

**Impact:** Provider onboarding proceeds with a broken/missing config scaffold.

**Fix:** Return the error from `bootstrap_global` and pattern match on it in the `with` chain.

---

### J11. `Env.apply_web_port` clobbers existing HTTP config

**`apps/lemon_core/lib/lemon_core/runtime/env.ex:169, 179`**

`Keyword.merge(existing, http: [...])` replaces the entire `:http` keyword. If existing config has other HTTP options (transport_options, compress, etc.), they're silently dropped.

**Fix:** Deep-merge the `:http` sub-keyword instead of replacing it.

---

### J12. `lemon.update` silently swallows start failure in check mode

**`apps/lemon_core/lib/mix/tasks/lemon.update.ex:191-193`**

When `check_only?` is true and `ensure_all_started` fails, the error is silently ignored. The function returns `nil`, and subsequent stages run without `lemon_core` loaded.

**Impact:** Cascading failures in check mode.

**Fix:** Return the error or halt the check pipeline.

---

### J13. Lockfile write failure silently returns `:ok`

**`apps/lemon_skills/lib/lemon_skills/installer.ex:283-285`**

When `Lockfile.write/2` fails (permission denied, disk full), the error is logged but the function returns `:ok`.

**Impact:** User thinks the install succeeded, but the lockfile is stale. Next load will not reflect the installed skill.

**Fix:** Propagate the error to the caller.

---

### J14. No file locking on lockfile — TOCTOU race

**`apps/lemon_skills/lib/lemon_skills/lockfile.ex` (entire module)**

`read/1` then `write/2` is a classic TOCTOU race. Two concurrent `mix lemon.skill install` invocations can clobber each other's lockfile writes.

**Fix:** Use `:file.lock/2` or an advisory lock file.

---

### J15. Bare `rescue _ ->` masks real bugs

**`apps/lemon_skills/lib/lemon_skills/sources/builtin.ex:80-82`**
**`apps/lemon_skills/lib/lemon_skills/installer.ex:464`**
**`apps/lemon_skills/lib/lemon_skills/migrator.ex:72-76`**

All three modules use bare `rescue _ ->` that catches everything and converts to generic errors. The migrator variant is worst — it returns a **success tuple** (`{:ok, :skipped}`) on crash.

**Fix:** Rescue specific exception types. Never return success on rescued crash.

---

### J16. `validate_string_list` doesn't verify element types

**`apps/lemon_skills/lib/lemon_skills/manifest/validator.ex:115-121`**

Checks that the value is a list but doesn't verify each element is a string. A manifest with `platforms: [1, true, nil]` passes validation.

**Impact:** Downstream code calling `Enum.join/2` or string functions on these values will crash at runtime, far from the validation boundary.

**Fix:** Add `Enum.all?(list, &is_binary/1)` check.

---

### J17. Release workflow `TIMESTAMP` references non-existent step output

**`.github/workflows/release.yml:212`**

```yaml
TIMESTAMP: ${{ steps.timestamp.outputs.timestamp || '' }}
```

There is no step with `id: timestamp` in the `publish` job. The shell variable `TIMESTAMP` is set correctly on line 182 via `$(date -u ...)`, but the `env:` block on line 209-212 overrides it with `''`.

**Impact:** `built_at` in `manifest.json` will always be an empty string.

**Fix:** Either remove `TIMESTAMP` from the env block, or add the timestamp step.

---

### J18. CHANGELOG claims Semantic Versioning but project uses CalVer

**`CHANGELOG.md:5`**

`Versions follow [Semantic Versioning](https://semver.org/)` directly contradicts the CalVer scheme (`YYYY.MM.PATCH`) documented in `docs/release/versioning_and_channels.md` and enforced by `release.yml` and `bump_version.sh`.

**Fix:** Reference CalVer instead.

---

### J19. Docs claim signed releases but workflow has no signing

**`docs/release/versioning_and_channels.md:41`**

Doc states: "A detached `.sig` file (ed25519) for artefact verification." But `release.yml` has no signing step — it builds tarballs, computes SHA-256 checksums, and publishes. No `.sig` file is generated.

**Fix:** Either add signing to the release workflow or remove the claim from docs.

---

### J20. `release-smoke.yml` ignores `workflow_dispatch` profile input

**`.github/workflows/release-smoke.yml:38-41`**

The matrix is hardcoded to `[lemon_runtime_min]`. The `workflow_dispatch` input `profile` (line 18-21) is defined but never referenced. Manual dispatch always tests `lemon_runtime_min` regardless of input.

**Fix:** Use `${{ github.event.inputs.profile || 'lemon_runtime_min' }}` like `product-smoke.yml` does.

---

### J21. Validator rejects the example config's queue mode

**`apps/lemon_core/lib/lemon_core/config/validator.ex:696` vs `examples/config.example.toml:82`**

`validate_queue_mode` allows `["fifo", "lifo", "priority"]` but the example config sets `mode = "collect"`. Running validation against the example config would produce an error.

**Fix:** Add `"collect"` to valid modes, or change the example.

---

### J22. Doctor check result silently swallowed in CI

**`.github/workflows/product-smoke.yml:132`**

`|| true` means the doctor check step never fails the build. A runtime returning bad status is logged but CI passes.

**Fix:** Remove `|| true`, or make it a real assertion.

---

### J23. No `permissions:` block on PR-facing workflows

**`.github/workflows/quality.yml`, `.github/workflows/release-smoke.yml`**

Unlike `docs-site.yml` which scopes `permissions:` explicitly, these inherit default token permissions. For PR workflows triggered by external contributors (if/when public), this could grant write access.

**Fix:** Add `permissions: contents: read` at minimum.

---

## Minor (35)

### Adaptive Behavior

#### m1. O(n) list append in `RolloutGate.check/3`

**`apps/lemon_core/lib/lemon_core/rollout_gate.ex:263`**

`reasons ++ [message]` is O(n). With only 3 gates this is negligible, but inconsistent with `RolloutGates` which correctly uses prepend + reverse.

---

#### m2. MapSet recreated on every call in `TaskFingerprint.matches_any?/2`

**`apps/lemon_core/lib/lemon_core/task_fingerprint.ex:144-145`**

`MapSet.new(keywords)` is called every time `classify_prompt` runs. Since the keyword lists are compile-time module attributes, the MapSets should be pre-computed as module attributes.

---

#### m3. Missing `@impl true` on catch-all `handle_info/2`

**`apps/lemon_core/lib/lemon_core/routing_feedback_store.ex:294`**

`def handle_info(_msg, state)` lacks the `@impl true` annotation, inconsistent with other callbacks in the same module.

---

#### m4. Flaky `Process.sleep(20)` in tests

**`apps/lemon_core/test/lemon_core/routing_feedback_store_test.exs:28`**
**`apps/lemon_core/test/lemon_core/routing_feedback_report_test.exs:28`**

Async cast wait uses a fixed 20ms sleep. Under load this is flaky. Consider a synchronous test helper or polling pattern.

---

#### m5. Custom section title used as XML tag without sanitization

**`apps/coding_agent/lib/coding_agent/prompt_builder.ex:250-258`**

`"<#{title}>\n#{content}\n</#{title}>"` — if `title` contains special characters (spaces, `>`, etc.), this produces malformed XML tags. Currently callers control `title`, but this is a latent injection surface if custom sections ever accept user input.

---

#### m6. Duplicated logic in `RunOutcome.infer_from_completed` / `infer_from_flat`

**`apps/lemon_core/lib/lemon_core/run_outcome.ex:123-175`**

These two functions are nearly identical. Could be refactored to a single helper that accepts the map to inspect.

---

### Memory System

#### m7. FTS query sanitization is incomplete

**`apps/lemon_core/lib/lemon_core/memory_store.ex:841-847`**

`sanitize_fts_query` strips `"*():.,!?;` but leaves FTS5 keyword operators (`OR`, `NOT`, `AND`, `NEAR`) and special characters (`^`, `{`, `}`, `-`) intact. A user searching for `"fix OR deploy"` gets a union query instead of an AND query.

**Fix:** Quote each token with `"token"` to force literal matching, or strip known FTS5 keywords.

---

#### m8. No limit cap on MemoryStore public API

**`apps/lemon_core/lib/lemon_core/memory_store.ex:287, 303, 319`**

`SessionSearch` caps limit at 20, but `MemoryStore.get_by_session/3` et al. pass the caller's limit directly to SQLite with no upper bound. Any internal caller could request `limit: 1_000_000`.

**Fix:** Add `min(limit, @max_limit)` clamp in the GenServer `handle_call` clauses.

---

#### m9. `compute_duration_ms/2` can return `nil`

**`apps/lemon_core/lib/lemon_core/memory_ingest.ex:145-151`**

The function has no `else` clause — if `started_at` is not an integer or `ingested_at <= started_at`, it implicitly returns `nil`. This `nil` is passed to `RoutingFeedbackStore.record/3` as the duration.

**Fix:** Return `0` or `:unknown` as a sentinel, or guard the `record/3` call.

---

#### m10. Delete-via-cast in mix task relies on `Process.sleep(200)`

**`apps/lemon_core/lib/mix/tasks/lemon.memory.ex:121`**

`run_erase` fires an async cast and then sleeps 200ms hoping it completes before the Mix process exits. Under disk pressure or large datasets, this is unreliable.

**Fix:** Make `erase` a synchronous `GenServer.call`, or flush the GenServer mailbox with a no-op call after the cast.

---

#### m11. Dead code: `@fts_prune_session_sql`

**`apps/lemon_core/lib/lemon_core/memory_store.ex:253-256`**

This SQL constant is defined but never prepared or referenced. The prune logic reuses `fts_sweep` instead (line 787).

**Fix:** Remove the dead constant.

---

#### m12. `enabled?/3` has dead `:on` branch

**`apps/lemon_core/lib/lemon_core/config/features.ex:139`**

`parse_state("on")` normalizes to `:"default-on"`, so the struct never contains `:on`. The `:on -> true` clause in `enabled?` is unreachable dead code.

---

### Runtime / Setup / Doctor

#### m13. `Health.do_await` can overshoot deadline by up to 500ms

**`apps/lemon_core/lib/lemon_core/runtime/health.ex:117`**

After a failed probe, `Process.sleep(@poll_interval_ms)` runs unconditionally even if remaining time is less than 500ms.

---

#### m14. `resolve_port` silently falls back on invalid port

**`apps/lemon_core/lib/lemon_core/runtime/env.ex:152-155`**

Setting `LEMON_WEB_PORT=99999` or `LEMON_WEB_PORT=abc` silently falls back to the default. No warning is logged, making misconfiguration hard to debug.

---

#### m15. Fragile 5-level `Path.expand` relative to `__DIR__`

**`apps/lemon_core/lib/lemon_core/runtime/env.ex:74`**

`Path.expand("../../../../..", __DIR__)` depends on exact directory depth. In a release, `__DIR__` points to the beam file location, which may not be 5 levels below the project root.

---

#### m16. Dead code branch in `check_lemon_root`

**`apps/lemon_core/lib/lemon_core/doctor/checks/runtime.ex:40-41`**

The `is_nil(root)` branch can never be reached because `Env.lemon_root/0` always returns a string (never nil).

---

#### m17. `ConfigMigrator.migrate!/1` double-parses TOML

**`apps/lemon_core/lib/lemon_core/update/config_migrator.ex:56-57`**

Reads and decodes TOML only to discard the result, then applies text-level regex transforms. The decode is used only for validation.

---

#### m18. TOCTOU race in `write_unless_exists`

**`apps/lemon_core/lib/lemon_core/setup/scaffold.ex:90-98`**

Race between `File.exists?` and `File.write`. Two concurrent processes could both see the file as absent and both write.

**Fix:** Use `File.open(path, [:write, :exclusive])` instead.

---

#### m19. `normalize_input` duplicated across 3 modules

**`apps/lemon_core/lib/lemon_core/setup/wizard.ex:333-337`**
**`apps/lemon_core/lib/lemon_core/setup/gateway.ex:116-120`**
**`apps/lemon_core/lib/lemon_core/setup/gateway/telegram.ex:241-245`**

Identical 5-clause function copy-pasted. Should be extracted to a shared module.

---

#### m20. `Report.print` hardcodes `Mix.shell()`

**`apps/lemon_core/lib/lemon_core/doctor/report.ex:66`**

Unlike the setup wizard which uses injected io callbacks, the doctor report is hardcoded to `Mix.shell()`. Inconsistency makes it harder to test.

---

### Skills System

#### m21. Case-insensitive registry ref matching contradicts docs

**`apps/lemon_skills/lib/lemon_skills/source_router.ex:103`**

```elixir
Enum.all?(parts, fn p -> String.match?(p, ~r/^[a-z0-9_-]+$/i) end)
```

The `i` flag allows uppercase, but the module doc says registry refs should be lowercase namespace segments.

---

#### m22. Git source doesn't clean up on failed first clone

**`apps/lemon_skills/lib/lemon_skills/sources/git.ex:43-66`**

`File.rm_rf(dest_dir)` runs before clone, but if the first clone attempt fails and leaves a partial directory, the retry doesn't clean it up first. The second attempt may fail with "directory exists."

---

#### m23. `unless` with side effects (style guide anti-pattern)

**`apps/lemon_skills/lib/lemon_skills/synthesis/draft_store.ex:159`**

```elixir
unless File.dir?(dir), do: File.mkdir_p!(dir)
```

Prefer `if not File.dir?(dir)` or just unconditionally call `File.mkdir_p!/1` (it's idempotent).

---

#### m24. Overly broad YAML key detection in manifest parser

**`apps/lemon_skills/lib/lemon_skills/manifest/parser.ex:128`**

```elixir
String.contains?(line, ":")
```

A value containing a colon (e.g., `description: "See https://example.com"`) triggers key detection on continuation lines. The parser partially handles this with `parts: 2` splitting, but edge cases around multiline values with colons can produce wrong parses.

---

#### m25. Incomplete YAML string escaping in draft generator

**`apps/lemon_skills/lib/lemon_skills/synthesis/draft_generator.ex:183-185`**

`yaml_string/1` only handles double quotes and newlines. YAML special characters like `:`, `#`, `{`, `}`, `[`, `]`, `|`, `>`, `!`, `%`, `@`, `` ` ``, `&`, `*` can break parsing. A skill name containing a colon (e.g., "k8s: deploy helper") produces invalid YAML.

---

### CI/CD & Infrastructure

#### m26. Cron comment contradicts cron value

**`.github/workflows/product-smoke.yml:16`**

Comment says "Daily at 05:30 UTC (off-peak, intentionally not :00 or :30)" but the cron is `"30 5 * * *"` — which IS at :30.

---

#### m27. MIX_ENV flip-flop for skill lint in CI

**`.github/workflows/product-smoke.yml:137-139`**

The workflow runs in `MIX_ENV=prod`, then the skill lint step does `MIX_ENV=dev mix deps.get` to re-fetch deps in dev mode. Wasteful (~30s+) and confusing.

---

#### m28. Overly broad permissions for PR builds

**`.github/workflows/docs-site.yml:31-34`**

`pages: write` and `id-token: write` are granted at the workflow level but only needed for the deploy job. PR builds don't deploy but still request these permissions.

---

#### m29. `bin/lemon` no port range validation

**`bin/lemon:140-153`**

The script validates ports are numeric (`^[0-9]+$`) but doesn't check the valid 1-65535 range. `--port 0` or `--port 99999` would be accepted.

---

#### m30. `bin/lemon` runs `mix deps.get` and `mix compile` on every startup

**`bin/lemon:179`**

Every invocation runs dependency fetch and compilation, even if nothing changed. Adds 5-15s to every launch.

**Fix:** Consider a staleness check (e.g., compare `mix.lock` mtime).

---

#### m31. Broken link check is permanently informational

**`.github/workflows/docs-site.yml:83`**

`continue-on-error: true` with comment "until baseline is established" but no tracking issue or TODO. Will likely remain permanently non-blocking.

---

#### m32. `fail_on_unmatched_files: false` in release workflow

**`.github/workflows/release.yml:240`**

If the build step silently produces no artifacts, a GitHub Release will be created empty.

**Fix:** Consider `true` to catch build failures.

---

#### m33. Unquoted file path in Python inline in bump_version.sh

**`scripts/bump_version.sh:83`**

`python3 -c "import json; d=json.load(open('$file'));..."` — if `$file` contained a single quote it would break. Low risk since paths are hardcoded, but fragile.

---

#### m34. Significant duplication between smoke workflows

**`.github/workflows/product-smoke.yml` / `.github/workflows/release-smoke.yml`**

Both workflows share ~70% identical structure. A reusable workflow or composite action would reduce maintenance burden.

---

#### m35. `String.to_atom/1` from user config input in validator

**`apps/lemon_core/lib/lemon_core/config/validator.ex:888`**

`String.downcase(value) |> String.to_atom()` in `validate_log_level/3` and `validate_theme/3`. Creating atoms from config strings can lead to atom table exhaustion.

**Fix:** Use `String.to_existing_atom/1` with a rescue, or match against a known allowlist.

---

## Nit (15)

### Adaptive Behavior

#### n1. `--family` flag not validated in `mix lemon.feedback`

**`apps/lemon_core/lib/mix/tasks/lemon.feedback.ex:89`**

Invalid family values (e.g., `--family bogus`) silently return empty results. Consider validating against `TaskFingerprint.task_families/0`.

---

#### n2. `classify_prompt` keyword priority undocumented

**`apps/lemon_core/lib/lemon_core/task_fingerprint.ex:134-139`**

Code keywords take priority over file_ops, query, chat. A prompt like "read and fix the config" matches `:code`. This priority is reasonable but not documented as a design decision.

---

### Memory System

#### n3. No tests for `SessionSearch`, `SearchMemory` tool, or `mix lemon.memory` task

Multiple modules lack dedicated test coverage. Concurrent-access tests for MemoryStore are also absent.

---

#### n4. `eventually` helper gives poor assertion messages

**`apps/lemon_core/test/lemon_core/memory_store_test.exs:212-221`**

When `eventually` returns `false`, the test fails with `"Expected truthy, got false"`. Adding a descriptive label would make CI failures easier to diagnose.

---

#### n5. `session_search_enabled?` duplicated

**`apps/lemon_core/lib/lemon_core/memory_ingest.ex:117-123`** and **`apps/lemon_core/lib/lemon_core/session_search.ex:83-88`**

Same logic in two places. Could extract to `LemonCore.Config.Features` as a convenience function.

---

#### n6. Perf test `make_doc` uses future timestamps

**`apps/lemon_core/test/lemon_core/memory_store_perf_test.exs:181`**

`now + i` for `ingested_at_ms` produces future timestamps. Functionally fine but semantically incorrect.

---

### Runtime / Setup / Doctor

#### n7. `Boot.start/2` returns indistinguishable `:ok` for both started and already-running

**`apps/lemon_core/lib/lemon_core/runtime/boot.ex:62`**

Could return tagged tuples for callers that need to differentiate.

---

#### n8. Infinite recursion in interactive helpers

**`apps/lemon_core/lib/lemon_core/setup/wizard.ex:329`**
**`apps/lemon_core/lib/lemon_core/setup/gateway.ex:105`**

`prompt_yes_no?` and `pick_adapter_interactively` recurse on invalid input with no depth limit. A buggy io callback causes stack overflow.

---

#### n9. Missing tests for multiple runtime/setup modules

No tests for: `Profile.default_name/0`, `Health.running?/2` success path, `Health.await/2` success path, `Wizard.run_full/3`, `Providers.run/1` / `Secrets.run/1` doctor checks, `Report.print/2`, `mix lemon.doctor` task.

---

#### n10. `Doctor.Checks.Providers` — no nil guard on config struct access

**`apps/lemon_core/lib/lemon_core/doctor/checks/providers.ex:21, 37`**

`config.agent.default_provider` and `config.providers.providers` assume these nested keys exist. If `Modular.load()` returns a struct with nil fields, this raises `KeyError`/`FunctionClauseError`.

---

### Skills System

#### n11. Unused alias in `trust_policy.ex`

**`apps/lemon_skills/lib/lemon_skills/trust_policy.ex:39`**

`alias LemonSkills.Entry` used only in `@spec` type reference.

---

#### n12. Inconsistent error tuple shapes across skill modules

Some modules return `{:error, :atom_reason}`, others `{:error, "string reason"}`, and some `{:error, %struct{}}`. Consider standardizing.

---

#### n13. `format_source` doesn't handle `:builtin` explicitly

**`apps/lemon_skills/lib/lemon_skills/tools/read_skill.ex:375-378`**

Falls through to `inspect(:builtin)` -> `":builtin"` which works but isn't user-friendly.

---

#### n14. No direct source module tests

`sources/github.ex`, `sources/git.ex`, `sources/registry.ex`, `sources/local.ex`, `sources/builtin.ex` have zero dedicated test files. All source logic is only indirectly tested through integration paths.

---

#### n15. `assert ... or true` in installer tests

**`apps/lemon_skills/test/lemon_skills/installer_test.exs`**

Several assertions use `assert ... or true` which makes them always pass. These tests provide false confidence.

---

## Test Coverage Gaps (consolidated)

| Area | Gap |
|------|-----|
| Adaptive | No end-to-end test for `resolve_history_model` with recorded feedback |
| Adaptive | No test for LIKE wildcard characters in workspace paths |
| Adaptive | No test clarifying which rollout gate module is used in promotion |
| Adaptive | No integration test for the orchestrator's history-based path |
| Adaptive | PromptBuilder tests don't exercise malicious custom section titles |
| Memory | No tests for `SessionSearch`, `SearchMemory` tool, `mix lemon.memory` |
| Memory | No test for `sanitize_fts_query` edge cases (FTS operators, empty strings, unicode) |
| Memory | No concurrent-access tests for MemoryStore |
| Runtime | No tests for `Profile.default_name/0`, `Health` success paths, `Wizard.run_full/3` |
| Runtime | No tests for `Providers.run/1`, `Secrets.run/1`, `Report.print/2`, `mix lemon.doctor` |
| Skills | No dedicated source module tests (github, git, registry, local, builtin) |
| Skills | No concurrent lockfile tests |
| Skills | No `synthesis/pipeline.ex` tests |
| Skills | Installer tests use `assert ... or true` (always-passing) |
| Skills | No negative manifest parser tests (malformed YAML edge cases) |
| Skills | No test for Mix task confirmation bypass (C8) |

---

## Security Positives

Not all findings were negative. The review identified several areas where security is handled well:

- **Path traversal protection is solid**: `read_skill.ex:320-323` and `skill_lint.ex:163-164` both properly validate expanded paths stay within skill directories.
- **XML escaping in `prompt_view.ex`** is correct (`&`, `<`, `>` handled).
- **Audit engine** covers the right categories (destructive commands, remote exec, exfiltration, path traversal, symlink escapes).
- **Trust policy** is clean, well-documented, and consistent.
- **README condensation** was done well — all deep content properly linked to docs/, no important content lost.

---

## Top 10 Priority Fixes

1. **C1** — Fix toolset mismatch in `resolve_history_model` (feature is completely inert)
2. **C2** — Resolve duplicate rollout gate modules (pick canonical, delete other)
3. **C3** — Fix release crash in `Profile.default_name/0` (startup blocker)
4. **C4** — Remove hardcoded dev cookie fallback (cluster security)
5. **C8** — Fix uninstall confirmation bypass (control flow bug)
6. **C6** — Remove trailing space in GitHub auth header (silent auth failure)
7. **J4** — Fix memory search scope escalation (data isolation violation)
8. **J3** — Fix UTF-8 truncation in memory documents (data corruption)
9. **C9-C11** — Fix security policy and example config (pre-public blockers)
10. **J17** — Fix broken release timestamp in workflow
