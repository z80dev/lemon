# BEAM Review Plan (Detailed)

## Scope
- **In scope:** `apps/ai` runtime architecture, provider streaming, event stream behavior, supervision tree, registry lifecycle, and OTP lifecycle semantics.
- **Out of scope (for now):** model metadata accuracy, provider API correctness, pricing tables, and UI or CLI integration.
- **Primary goal:** Make the AI runtime resilient, supervised, and backpressure-aware using BEAM/OTP patterns.
- **Secondary goal:** Keep API changes minimal and explicit, so downstream apps can migrate safely.

---

## Findings (Current Gaps)

1) **Provider registry loses state on crash**
   - **Impact:** If `Ai.ProviderRegistry` crashes/restarts, providers are gone until manual re-registration.
   - **Evidence:** Providers are registered once in `Ai.Application.start/2`; `ProviderRegistry.init/1` always starts empty.
   - **Risk:** A single crash silently disables all providers.

2) **Streaming tasks are unsupervised and unlinked**
   - **Impact:** `Task.start/1` runs outside the supervision tree. If the caller or `EventStream` dies, the HTTP task keeps running. Failures are hidden.
   - **Evidence:** Providers (`OpenAIResponses`, `Anthropic`, etc.) spawn tasks directly.
   - **Risk:** Orphaned HTTP calls, resource leaks, no restart visibility.

3) **Unbounded event buffering without backpressure**
   - **Impact:** `EventStream` enqueues indefinitely under slow consumers.
   - **Evidence:** No queue limits or demand signaling; producer uses `GenServer.cast/2` with no flow control.
   - **Risk:** Memory blowup, latency spikes under load.

4) **No cancellation or timeout propagation**
   - **Impact:** Streams can run forever even when consumers are gone.
   - **Evidence:** No cancellation API; no owner monitoring; `result/2` can block indefinitely.
   - **Risk:** Stuck requests, wasted resources.

---

## Target Architecture (High-Level)
- **Static provider registry** (or resilient dynamic registry) that survives restarts.
- **Supervised streaming tasks** under `Task.Supervisor` (or `DynamicSupervisor`).
- **Event stream with bounded queues or demand-based backpressure.**
- **Explicit lifecycle ownership** and cancellation, with timeouts propagated to HTTP streams.

---

## Detailed Plan and Ordering

### Phase 0 — Baseline Documentation and Invariants
**Goal:** Make design intent explicit to avoid regressions.
- **Files:** `apps/ai/README.md` (or new `docs/beam.md` if preferred).
- **Changes:**
  - Document current streaming flow and expected lifecycle.
  - Define invariants: “provider registry must be available after restart”, “streams must stop if owner exits”, “queue must not grow unbounded.”
- **Acceptance:** Doc exists and lists invariants + ownership model.

---

### Phase 1 — Provider Registry Resilience (Highest ROI)
**Goal:** Ensure registry survives crashes and restarts.

#### Recommended approach (simple + robust): static map + lookup helper
- **Changes:**
  1) Replace `Ai.ProviderRegistry` GenServer with a static map or `:persistent_term`.
  2) Expose `ProviderRegistry.get/1` reading from that static map.
  3) Optional: keep `register/2` for tests, but gate with config or use in dev only.

#### Code-level proposal
- **New module or rewrite:**
  - Keep `Ai.ProviderRegistry` as a module with a module attribute map, or store in `:persistent_term` during application start.
- **Example implementation:**
  - In `Ai.ProviderRegistry`:
    - `@providers %{ :anthropic_messages => Ai.Providers.Anthropic, ... }`
    - `def get(api_id), do: Map.fetch(@providers, api_id)`
  - Or use `:persistent_term.put({__MODULE__, :providers}, map)` in `Ai.Application.start/2` and `get/1` reads it.

#### Alternate approach (if dynamic registration is required)
- Keep GenServer but re-register in `init/1` or on startup:
  - `def init(_) do state = %{providers: default_providers()}; {:ok, state} end`.
  - Move registration into `Ai.ProviderRegistry.default_providers/0` so it is deterministic.

**Acceptance:** After killing `Ai.ProviderRegistry`, calling `get/1` still succeeds without manual re-registration.

---

### Phase 2 — Supervise and Link Streaming Tasks
**Goal:** All provider stream tasks should be supervised and lifecycle-linked.

#### Code-level proposals
1) **Add a Task Supervisor to the application tree**
   - **File:** `apps/ai/lib/ai/application.ex`
   - **Add child:** `{Task.Supervisor, name: Ai.StreamTaskSupervisor}`

2) **Start tasks under supervision**
   - Replace `Task.start(fn -> ... end)` with:
     - `Task.Supervisor.start_child(Ai.StreamTaskSupervisor, fn -> ... end)`
   - Store returned task pid if needed (see cancellation).

3) **Link stream ownership to caller**
   - Modify `EventStream.start_link/1` to accept `owner: pid` (default to `self()`).
   - In `EventStream.init/1`, monitor `owner` and terminate or cancel the stream task on `:DOWN`.

#### Example API changes
- `EventStream.start_link(owner: pid, task_pid: pid)`
- `EventStream.attach_task(stream, task_pid)`
- `EventStream.cancel(stream, reason \\ :canceled)`

**Acceptance:** Killing the caller stops the HTTP task and terminates the stream cleanly.

---

### Phase 3 — Bounded Buffer or Demand-Based Backpressure
**Goal:** Prevent unbounded memory growth.

#### Option A (recommended): Bounded queue
- **Changes to `EventStream`:**
  - Add `max_queue` option (default e.g., 1000 events).
  - Track queue size in state.
  - When size exceeds max:
    - Strategy `:drop_oldest` or `:drop_newest` (configurable), or
    - `EventStream.error/2` and stop stream.

#### Option B: GenStage-based stream
- Replace `EventStream` with a GenStage producer that delivers events only when demanded.
- Requires consumer changes (slightly more invasive).

#### Minimal code-level design for Option A
- `EventStream.start_link(max_queue: 1000, drop_strategy: :drop_oldest)`
- `push/2` returns `:ok | {:error, :overflow}`
- Providers check `push/2` result; on `{:error, :overflow}` call `EventStream.error/2` and stop HTTP stream.

**Acceptance:** Under a slow consumer, queue length never exceeds configured max; overflow is handled deterministically.

---

### Phase 4 — Cancellation and Timeout Propagation
**Goal:** Stop streams cleanly and avoid hung HTTP tasks.

#### Code-level proposals
1) **Cancellation API**
   - Add `EventStream.cancel/2` which sends a cancel message and marks stream as done.
   - On cancel, terminate the provider task (if tracked) using `Task.shutdown/2`.

2) **Owner monitoring**
   - In `EventStream.init/1`, call `Process.monitor(owner)`.
   - On `:DOWN`, call `cancel/2`.

3) **Provider-side cancellation hook**
   - In provider streaming loops, watch for a cancellation message (e.g., `{:cancel, reason}`) and stop the Req stream.
   - In OpenAI streaming loop, break out of `receive` if canceled.

4) **Timeout propagation**
   - Add explicit `:stream_timeout` option in `StreamOptions`.
   - Pass `receive_timeout` and/or `read_timeout` into `Req.post/2`.
   - On timeout, emit a `{:error, :timeout}` event and stop the stream.

**Acceptance:** Canceling a stream halts the HTTP task within a bounded time and returns a terminal event.

---

## Ordering and Dependency Notes
1) **Phase 1** should happen first because it removes a reliability single-point failure.
2) **Phase 2** depends on Phase 1 only in a minor way (application tree changes). It can proceed once the supervisor exists.
3) **Phase 3** should follow Phase 2 because backpressure requires predictable task lifecycle and cancellation paths.
4) **Phase 4** is safest after Phase 2/3, since cancellation must know how to stop supervised tasks and manage overflow.

---

## Proposed API Evolution (Explicitly Versioned)
- `EventStream.start_link/1` adds options: `owner`, `max_queue`, `drop_strategy`.
- `EventStream.push/2` returns `:ok | {:error, reason}` (breaking change if callers assume `:ok`).
- `EventStream.cancel/2` new API.
- Providers updated to handle `push/2` overflow result and cancellation.

---

## Test Plan (Additions)
- **Registry resilience test:** Kill and restart registry; `get/1` still succeeds.
- **Stream task supervision test:** Force task crash; ensure supervisor reports it.
- **Backpressure test:** Flood stream; verify queue size cap and overflow behavior.
- **Cancellation test:** Cancel stream; ensure task stops and terminal event emitted.
- **Timeout test:** Force slow stream; ensure timeout triggers error event.

---

## Expected Benefits
- Stronger crash recovery and OTP-aligned lifecycle.
- Predictable memory use under load.
- Clean cancellation and termination semantics.
- Safer foundation for scaling an AI app on BEAM.
