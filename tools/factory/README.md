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
- Integration, releases, CI policy, GitHub settings, and paid benchmarks stay
  manual. READY is a retained handoff, not certification.
- Not yet built (seeded as P04–P08): stable `factory/<task>/<attempt>` refs and
  check-runner receipts, review records, parallel slots beyond one, CI observation,
  issue import, and integration policy.

## Tests

```bash
python3 -m unittest discover -s tools/factory/tests -t tools/factory
```

`test_omp_seams` and `test_supervisor` drive the installed `omp` with a
deterministic scripted provider (`omp_adapter/fixture_provider.ts`) in a private
agent directory: no network and no paid calls. `factory compat` runs the seam
suite and refuses to stamp a build that fails it.
