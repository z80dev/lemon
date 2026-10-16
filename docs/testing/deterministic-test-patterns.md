# Deterministic Test Patterns

This guide captures the patterns Lemon uses to keep CI signal deterministic and regression-focused.

## 1) Do not skip tests in-tree

- Do not commit `@tag :skip`, `@tag skip: ...`, `@moduletag :skip`, or `@describetag :skip`.
- Tests that need an optional host tool use a named tag that the app's `test_helper.exs` excludes when the tool is missing (for example `:python3` in `coding_agent`).
- If a test is flaky, fix determinism first (mocking, synchronization, fixture isolation).
- CI enforces this with the skip-tag guard in `scripts/test quality`.

## 2) Prefer explicit synchronization over `Process.sleep/1`

- Use mailbox assertions (`assert_receive`/`refute_receive`) with clear timeouts.
- Use latch/poll helpers when coordination is required: `LemonCore.Testing.AsyncHelpers` (`apps/lemon_core/lib/lemon_core/testing/async_helpers.ex`: `assert_eventually/2`, `assert_process_dead/2`, latches, barriers). `coding_agent` and `lemon_gateway` expose thin `AsyncHelpers` wrappers in their `test/support`.
- Wait for concrete state transitions/events, not elapsed time.
- For transient LiveView states such as an async submit button's busy indicator,
  assert against the HTML returned by the triggering `render_submit` or
  `render_click`. A later `has_element?` request races the async completion.
  Use `render_async` before checking the settled UI; the captured event-reply
  snapshot remains valid even after that completion barrier.

## 3) Reset global/shared test state

When tests rely on process-global or ETS-backed fixtures:

- reset in `setup`
- register `on_exit` cleanup
- avoid cross-test coupling through named global modules

Example pattern:

```elixir
setup do
  HttpMock.reset()
  on_exit(&HttpMock.reset/0)
  :ok
end
```

## 4) Stub external I/O deterministically

- Replace network/process dependencies with predictable stubs.
- Include both happy-path and error-path fixtures.
- Keep assertions scoped to stable outputs (avoid brittle string fragments where possible).

## 5) Use threshold-safe assertions for fuzzy/scored behavior

For ranking/fuzzy matching tests:

- assert strategy/path taken
- assert confidence/range bounds (e.g. `>= 0.92`)
- avoid exact score equality unless mathematically guaranteed

## 6) Add focused regression loops for historically flaky suites

Run critical deterministic suites more than once in CI to catch reintroduced flakes early. `nightly.yml` runs the prompt/skill/overflow regression files with `--repeat-until-failure 5` and `scripts/test eval-fast` with 20 iterations. Keep these loops targeted to avoid excessive runtime.
