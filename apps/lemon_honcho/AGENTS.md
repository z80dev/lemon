# LemonHoncho contributor guide

Honcho is an optional satellite memory integration. It contributes cached context,
explicit tools and a memory provider through platform registries. See
[README](README.md) and [operator guide](../../docs/user-guide/honcho.md).

## Dependency and test isolation

- Dependency direction is satellite → platform only. Platform apps must not
  reference `LemonHoncho` or add a dependency. Root release composition, the env
  registry entry and test isolation config are explicit integration points.
- The application registers its memory provider, context contributor and tools only
  when configured at boot. Per-tool configuration gates remain necessary if config
  later becomes invalid. Optional missing registries must not fail boot.
- Tests pin `enabled: false`, `start_session_manager: false` and the
  `LemonHoncho.Client.Tripwire` transport. Env can override enablement, so the
  tripwire is essential to stop a developer's real credentials leaking test data.
  Client tests install their own stub and restore application env.
- `enabled?` is not `configured?`; the latter also requires credentials or a base
  URL. Config typos degrade to defaults rather than failing runtime boot.

## Turn path and caching

- Warm-turn context reads return cached data, never synchronous remote requests.
  The cold-first-turn exception needs both contributor timeout negotiation and
  manager waiters. Derive the wait from the registry-clamped budget minus elapsed
  time/headroom so it completes inside the registry deadline.
- Keep cold detection O(1). Waiters must receive a reply on success, timeout or
  worker death; a failed refresh must not strand the agent turn.
- Base-context and dialectic cadences are independent. Advance markers at refresh
  start, not success, so an outage costs one attempt per window, not every turn.
  Changing cadence changes remote/model spend and belongs in the operator guide.
- Stable material belongs in system context; volatile dialectic material belongs
  in a user-message contribution. Label recalled context as background, not user
  instructions. Hide injected blocks from user transcripts/hooks/UI while keeping
  their exact bytes in model replay history for prompt-cache stability.
- Respect contributor size/time bounds and the local context-token budget; do
  not raise global registry limits to accommodate an overgrown Honcho block.
- Session entries are bounded and idle-evicted through `track_entry/3`. Refresh
  workers and waiters pin entries; both reads and uploads touch them. Entries are
  reconstructible cache, not durable state. Never bypass admission/eviction.
- Session names preserve a hash of the original key after sanitization/truncation
  so long or punctuation-different keys cannot merge private memory.

## Privacy and remote failures

- Remote outages cost the turn its memory block, not its ability to run. Provider
  failures return `[]`; scoped searches without a scope key also return `[]`,
  never widen to a workspace-wide query.
- Every prose field sent remotely goes through `Egress.screen/2`: clip to the
  call-site budget first, screen the bytes that would travel, then withhold the
  whole value on a suspected credential. Never partially redact-and-send or log
  withheld input. Blank/invalid text also has a normal no-text path.
- Tools refuse screened requests instead of claiming an empty query answered the
  original request. Profile replacement refuses the whole write if any line is
  unsafe; sending only survivors would delete withheld lines remotely.
- `save_messages?: false` is read-only: block uploads, profile writes and conclusion
  create/delete, while retaining reads. New remote mutations inherit this gate.
- `recall_mode: :tools` disables injection; `:context` gates explicit Honcho tools.
  Provider search is a separate registry seam. Subagent injection defaults off.
- Uploads ride memory ingest and carry bounded prompt/answer summaries, not raw
  transcripts. Ingest remains gated by `session_search`; read success alone does
  not prove anything is being uploaded.

## Diagnostics and verification

Status/ping use explicit total deadlines and no diagnostic retries. Keys are
reported as present/absent; upstream errors are scrubbed before truncation.
`context` is cache-only unless `--live` is explicit and announced because a live
lookup advances cadence and can incur cost.

The Mix task starts its own VM. Its `sessions`/`context` list that VM's cache,
not the running assistant's or Honcho's complete store. Absence from the cache
is never proof of missing remote memory. Config/reachability status transfers
between VMs; per-session cache state does not.

From the umbrella root: `mix test apps/lemon_honcho/test`.
Exercise cold/warm timeout negotiation, egress withholding, read-only modes,
scoped absence, eviction with waiters, and remote errors using injected clients.
