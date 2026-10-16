# Lemon factory (development tooling)

An external development tool that sits beside Lemon, not inside it. Any OMP console
can start the factory, add work, and control it. All consoles share one durable
queue and one managed OMP coordinator that dispatches native OMP `task` workers.
Nothing here is a Lemon application or part of the umbrella build.

```text
OMP console A ─┐                       ┌─ supervisor (kernel lock, wake-ups, lifecycle)
OMP console B ─┼─ factory CLI ─ ledger ┤
plain shell   ─┘   (cli.py)   (SQLite) └─ one `omp --mode rpc` coordinator ─ native isolated task workers
```

|Path|Role|
|---|---|
|`.factory/project.json`|Portable project identity (`lemon`, `github.com/z80dev/lemon`)|
|`.factory/charter.md`|Coordinator instructions and authority limits (appended to its system prompt)|
|`.factory/policy.example.json`|Policy template; the approved copy lives in the state directory|
|`.factory/seed-work.json`|Approved plan packets P04–P08 for `factory seed`|
|`tools/factory/cli.py`|The only implementation of ledger rules; every command prints one JSON object|
|`tools/factory/store.py`|SQLite ledger: tasks, attempts, events, request keys, runtime|
|`tools/factory/supervisor.py`|Supervisor daemon and start/stop/pause/drain operations|
|`tools/factory/compat.py`|OMP seam suite gate and compatibility stamp|
|`tools/factory/omp-overlay.yml`|The only OMP settings the factory pins (async workers, structured output, isolation without apply)|
|`integrations/omp-factory/`|OMP plugin: console `factory` tool, `/factory` command, coordinator tools, `lemon-factory` skill|

Host-local state (never in Git; `0700`): `~/.config/software-factory/projects.json`,
`~/.local/state/software-factory/<project>/` (`factory.db`, `runtime.lock`,
`policy.json`, `checkout/`, `sessions/`, `logs/`), the OMP compatibility stamp
`~/.local/state/software-factory/omp-compat.json`, and installed releases under
`~/.local/share/software-factory/`. `FACTORY_CONFIG_HOME`, `FACTORY_STATE_HOME`,
and `FACTORY_DATA_HOME` override these roots.

## Setup

```bash
F=tools/factory/cli.py
python3 $F compat                 # run the OMP seam suite; stamp this exact omp build
python3 $F install --ref HEAD     # git-archive a committed version; `omp plugin link` it
python3 $F register               # from a checkout containing .factory/project.json
cp .factory/policy.example.json ~/.local/state/software-factory/lemon/policy.json   # review first
```

`install` only adds an OMP plugin link: no settings, model roles, or aliases change.
The coordinator uses the profile's own default model and task-agent overrides;
startup fails if OMP resolves a different default than the profile configures.

## Use

From any OMP session: "Start the Lemon factory", "Add this to the factory: …", or
`/factory start | add <request> | status | show F-0001 | list | prioritize F-0001 high | pause | resume | drain | stop`.
From a shell, `python3 ~/.local/share/software-factory/current/tools/factory/cli.py <command>`;
from another machine, run that over SSH. Never share the SQLite file across hosts.

- `add` commits the task and its `task.created` event in one transaction and returns
  the ID only afterwards. Request keys make replays return the same task; a reused
  key with a different payload is a conflict. Adding while stopped only queues.
- Edits carry an expected revision; a stale revision fails with the current task.
- `start` is idempotent: concurrent starts race for a kernel `flock`, and losers exit.
  The supervisor validates policy, release, compatibility stamp, and git identity,
  prepares a clean detached worktree at the project's `base_ref`, reconciles
  attempts from earlier epochs, then launches `omp --mode rpc` with `--continue`.
- The supervisor wakes the coordinator only for new ledger events not made by the
  coordinator itself, coalesced into one prompt (queued as a follow-up while busy).
  An idle queue costs no model requests. Events stay unprocessed until the
  coordinator checkpoints them.
- `pause` and `drain` take effect in `reserve` admission immediately, before any
  model turn. `drain` stops once settled; `stop` aborts the turn, cancels workers,
  closes stdin, waits, and only then force-kills the process tree (tool shells run
  in their own process groups, so descendants are reaped explicitly). `stop --abort`
  kills immediately and marks in-flight attempts `orphaned` with tasks `blocked`.
- Closing a console never affects the coordinator; the supervisor is a separate session.

## Pipeline

```text
inbox ─triage→ queued ─implement/repair worker→ ready ─reviewer→ verifying ─integrator→ awaiting_merge → landed_pending_confirmation → done
                 ↑                                     │ changes requested         │ CI failure / conflict (bounded repairs)
                 └─────────────────────────────────────┴───────────────────────────┘
```

- The coordinator reviews every READY task with OMP's read-only `reviewer` agent
  (strict review schema); blocker/major findings send it back as a repair.
- With policy `merge_policy: "auto-verified"` the supervisor's deterministic
  integrator (`integrator.py`) takes `verifying` tasks: cherry-picks the retained
  worker commit onto current `origin/main` (kept under `refs/factory/<task>/<attempt>`),
  force-pushes the factory-owned `factory/<task>` branch, opens or updates the PR,
  waits for the `CI` workflow run on that exact head, merges with
  `--match-head-commit`, then waits for main's CI on the actual merge commit before
  marking the task done. CI failures (log tail stored as untrusted data under
  `artifacts/ci/`) and conflicts become repairs, up to `max_repair_attempts`, then
  `blocked`. A red main after merge blocks the task and opens one urgent triage
  task. No admin merges, reruns, or pushes to `main`. `manual` disables all of it.
- Admission also enforces `max_ready_backlog` (tasks awaiting review/integration),
  `max_attempts_per_day`, per-stage slots, and refuses while the supervisor moves
  an idle coordinator checkout to the newest base (`base_refresh_interval_s`).
- `factory ensure` restarts a factory that should be running (it respects an
  operator `stop` and backs off after three failures in an hour).
  `factory autostart` installs a launchd agent running `ensure` at login and every
  five minutes from the installed `current` release; `--disable` removes it.

## Dashboard

```bash
python3 tools/factory/cli.py dashboard            # http://127.0.0.1:8765/ ; --port N, --port 0 for a free port
```

A read-only, loopback-only page (`tools/factory/dashboard/`, standard library only) showing runtime
health, tasks by pipeline status, live attempts, integration PR/CI state with the stored CI failure
log tail, the event feed and the supervisor log tail. It re-reads the ledger through `store.Ledger`
and `supervisor.health` and refreshes every two seconds. It prints one JSON line with the URL, then
serves until interrupted. It binds `127.0.0.1` only (other `--host` values are refused), answers
only `GET`/`HEAD` (everything else is `405`), rejects non-loopback `Host` headers, has no controls,
and renders all ledger, CI and log text HTML-escaped. For a remote factory, tunnel the port over SSH.

## Guarantees and limits

- Single host, single user, cooperative trusted-owner threat model. Worktrees and
  same-user files are not a sandbox; do not run untrusted forks through it.
- Workers run isolated with `task.isolation.apply=false`: results stay on
  `omp/task/<attempt>` and never touch the coordinator checkout or `main`.
  Isolated workers clone the coordinator checkout, ignored files and uncommitted
  state included, so `reserve` refuses dispatch unless that checkout is clean at
  the recorded base. Before launching the coordinator, the supervisor seeds
  ignored build inputs (`checkout_seed_from_primary`, copy-on-write clones of the
  primary checkout's `deps`/`_build`) and runs `checkout_setup` (`mix deps.get`,
  test compile), so workers can run real focused checks. Setup that dirties the
  checkout blocks startup.
- OMP keeps finished workers' isolation workspaces until the owning OMP process
  exits; the supervisor then removes the ones that process owned (results stay on
  their branches) and never touches other sessions' workspaces.
- OMP's strict output schema coerces scalars; handoffs are validated against the
  actual branch diff, not trusted as evidence.
- Releases, CI policy, GitHub settings, and paid benchmarks stay manual; workers and
  the coordinator never push or open PRs.
- Not yet built: check-runner receipts bound to source identity, inherited-failure
  attribution beyond a triage task, GitHub issue import, and measured optimization
  (remaining scope of seeded P04–P08).

## Tests

```bash
python3 -m unittest discover -s tools/factory/tests -t tools/factory
```

`test_omp_seams` and `test_supervisor` drive the installed `omp` with a
deterministic scripted provider (`omp_adapter/fixture_provider.ts`) in a private
agent directory: no network and no paid calls. `factory compat` runs the seam
suite and refuses to stamp a build that fails it.
