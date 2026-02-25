# Deterministic Test Patterns

This guide captures the patterns Lemon uses to keep CI signal deterministic and regression-focused.

## 1) Do not skip tests in-tree

- Avoid `@tag :skip` / `@tag skip: ...` in committed tests.
- If a test is flaky, fix determinism first (mocking, synchronization, fixture isolation).
- CI enforces this with a skip-tag guard in `.github/workflows/quality.yml`.

## 2) Prefer explicit synchronization over `Process.sleep/1`

- Use mailbox assertions (`assert_receive`/`refute_receive`) with clear timeouts.
- Use latch/poll helpers (for example `AsyncHelpers`) when coordination is required.
- Wait for concrete state transitions/events, not elapsed time.

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

Run critical deterministic suites more than once in CI to catch reintroduced flakes early. Keep these loops targeted to avoid excessive runtime.
