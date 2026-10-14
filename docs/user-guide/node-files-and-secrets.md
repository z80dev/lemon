# Execution-node files, secrets and native processes

These control-plane `/ws` methods operate on the **destination execution node**,
not on the controller's filesystem. Use the enrolled machine's durable `nodeId`.
The destination must be online. Requests use the normal authenticated `req` /
`res` protocol; a successful response's `payload` contains the shapes below.
Handlers dispatch asynchronously so other socket traffic can continue.

`node.host.info` requires operator `read`. **Every `node.fs.*`,
`node.secrets.*` and `node.process.*` method requires operator `admin`,
including reads, lists and read-only process receipt lookup.**
Keep the operator token in a trusted backend; do not distribute it to product
users. Secret and file bytes necessarily cross the authenticated node transport:
use `wss://` or an explicitly trusted encrypted overlay.

## Destination policy and configuration

The default file-policy root is the destination OS user's **home directory**.
Relative paths are resolved from the worker's destination-local default cwd,
selected by `lemon node join --cwd`. Setting a cwd outside home does not itself
grant file access there. Grant extra directories explicitly on the destination:

```bash
lemon node join --name worker-1 --controller wss://controller.example/ws \
  --cwd /srv/project --allowed-root /srv/project --allowed-root /mnt/results
```

`--allowed-root PATH` is repeatable; the CLI retains the home root and adds the
specified roots. Roots must be existing directories. Choose narrowly scoped
roots rather than `/`. Paths and roots are destination-local; nothing in the RPC
request can change this policy. The facade's worker-owned options are
`:default_cwd` and `:allowed_roots`; without options both default to home. An
explicit programmatic `:allowed_roots` list replaces the fallback and must be
nonempty (at most 64 roots).

Paths must be nonempty UTF-8 strings, at most 4096 bytes, with no NUL. `..` path
components are rejected, even when they would normalize back inside a root.
Containment is component-aware, not a string-prefix permission. Existing
symlinks are followed component by component; the canonical result must remain
under an allowed canonical root. This also rejects escapes through symlinked
parents of files that do not yet exist, dangling links to outside roots, and
link cycles. Symlinks whose targets stay inside allowed roots are accepted.
Returned file paths are absolute canonical destination paths and can be reused
in later calls. Operations on an accepted symlink act on its canonical target.

File operations require **Python 3** on the destination. A worker-owned service
pins allowed-root directory descriptors, explicitly resolves admitted symlinks,
and opens components relative to those descriptors with `O_NOFOLLOW`. A symlink
substituted after admission cannot redirect an open into an outside directory.
Roots stay bound to their opened directory identities until the service restarts.
This is **not an OS sandbox**: another local process can modify or move an
already-open inode, and multi-file recursive deletion is not an all-or-nothing
transaction against external writers. Host shells, tools and extensions execute
with the worker OS account's permissions. Use a dedicated OS account/container
and OS permissions for untrusted workloads. Profile identity does not isolate
that account's files or credentials.

## Host information

Request: `node.host.info {nodeId}`.

Response:

```json
{
  "hostname": "worker-host",
  "os": "linux",
  "osVersion": "6.8.0",
  "arch": "aarch64-unknown-linux-gnu",
  "cpuCount": 8,
  "memTotalBytes": 16777216000,
  "memFreeBytes": 2147483648,
  "diskTotalBytes": 500000000000,
  "diskFreeBytes": 100000000000,
  "uptimeSec": 12345,
  "lemonVersion": "2026.10.3",
  "defaultCwd": "/srv/project",
  "user": "lemon"
}
```

The example illustrates fields, not fixed values. Metrics are obtained from the
actual destination: Linux `/proc`, macOS `sysctl` / `vm_stat`, and POSIX `df` for
the filesystem containing `defaultCwd`. `memFreeBytes` means genuinely free
pages, not estimated reclaimable/available memory. `arch` is the BEAM system
architecture string; `lemonVersion` is the canonical installed Lemon CalVer.
Supported macOS/Linux snapshots require real measurements. A failed or unsupported
measurement returns `UNAVAILABLE`, **never null metrics or invented zeroes**.
Read-only host metadata remains available even if cwd is outside file roots.

## File operations

All requests include `nodeId`. Optional fields are in brackets here; send normal
JSON properties without brackets.

| Method | Request fields besides `nodeId` | Successful payload |
| --- | --- | --- |
| `node.fs.list` | `path, [showHidden=false]` | `{path, entries, limit:500, truncated}` |
| `node.fs.stat` | `path` | `{path, type, size, mtimeMs, mode, mime, readable, writable}` |
| `node.fs.read` | `path, [offset=0, length=1048576]` | `{path, dataBase64, offset, length, size, mime, eof}` |
| `node.fs.write` | `path, dataBase64, [offset=0, truncate=true, mkdirs=false, expectedModifiedAtMs]` | `{path, offset, bytesWritten, size, mtimeMs}` |
| `node.fs.mkdir` | `path` | `{path, created:true}` |
| `node.fs.move` | `path, destination, expectedModifiedAtMs, [overwrite=false]` | `{path, destination, moved:true}` |
| `node.fs.delete.preview` | `path, [recursive=false]` | `{path, stat, childCount, childrenDigest, candidateCount, confirmationToken, expiresAtMs}` |
| `node.fs.delete` | `path, confirm, confirmationToken` | `{path, deleted:true}` |

Directory entries include `name` plus the stat fields. Listing uses `lstat`:
symlink entries show `type:"symlink"`, with no link target disclosure or
recursive walk. An entry that disappears or becomes unreadable during listing
has `{name,error}` instead. Entries are sorted by name; dot-prefixed names are
hidden unless `showHidden:true`. Output stops at 500 entries and reports
`truncated:true` when more visible entries exist. There is no pagination cursor.
`type` follows filesystem types such as `regular`, `directory`, and `symlink`.
`size` is bytes, `mtimeMs` is the actual destination stat modification time in
integer Unix milliseconds (nanoseconds truncated to milliseconds), `mode` is the
integer filesystem mode, and MIME is inferred from the filename, not content.
`readable` and `writable` are actual worker-account OS access checks (including
ACLs), not deductions from mode bits; they are observations, not access promises
against subsequent local changes.

Reads/writes accept regular files only. Offsets count **decoded bytes**, not
base64 characters. Offsets are nonnegative integers, at most
9,007,199,254,740,991. Read `length` must be between 1 and 1,048,576 bytes.
A chunk may be shorter than requested; response `length` is its actual decoded
byte count, `size` is the observed file size, and `eof` indicates that the chunk
reaches or passes that size. Reading at/beyond EOF returns empty `dataBase64`
and `eof:true`. Concurrent local modifications can change the observed file;
this is not a snapshot protocol.

Each write's `dataBase64` must be valid standard base64 decoding to **at most
1 MiB**. Oversized decoded data is rejected before creating a target or parents.
Empty data is allowed. `mkdirs:true` creates missing parent directories; otherwise
parents must exist. Writes create a missing file or write at `offset` in an
existing file. `truncate:true` truncates **after writing**, at
`offset + bytesWritten`; it does not erase the prefix before the offset.
`truncate:false` preserves any existing suffix. Upload in bounded chunks:

Writes to an **existing file require `expectedModifiedAtMs`**, copied from its
latest `node.fs.stat` or listing entry's `mtimeMs`. `0` requires the file to be
missing; omission is allowed only for a missing target. A mismatched/missing
existing-file revision returns `revision_conflict` without writing the file.
Worker requests, including symlink aliases, are serialized so revision comparison
and writing cannot interleave. Each successful worker write advances the file's
millisecond mtime, even if the filesystem clock tick did not advance. This CAS
contract does not lock out unrelated local processes. Carry each successful
write receipt's `mtimeMs` directly into the next chunk's `expectedModifiedAtMs`;
do not reuse the revision supplied to the previous write.

```json
{"type":"req","id":"upload-1","method":"node.fs.write","params":{"nodeId":"node-id","path":"results/note.txt","dataBase64":"SGVsbG8g","offset":0,"truncate":true,"mkdirs":true,"expectedModifiedAtMs":0}}
```

Use the first write response's `mtimeMs` for the next chunk. For example, **if** the
returned value is `1791936000123`:

```json
{"type":"req","id":"upload-2","method":"node.fs.write","params":{"nodeId":"node-id","path":"results/note.txt","dataBase64":"d29ybGQ=","offset":6,"truncate":true,"expectedModifiedAtMs":1791936000123}}
{"type":"req","id":"read-1","method":"node.fs.read","params":{"nodeId":"node-id","path":"results/note.txt","offset":0,"length":6}}
```

The first read yields decoded `Hello `, `size:11`, `length:6`, `eof:false`.
Read the next chunk at offset 6 to receive `world` and `eof:true`. Clients must
also respect the connection's negotiated JSON payload cap: base64 requires
approximately 4/3 of the decoded size plus protocol overhead.

`mkdir` creates parent directories and is idempotent for an existing directory.
`move` requires the source's observed `mtimeMs` as `expectedModifiedAtMs`.
It defaults to **no overwrite**, returning `already_exists` if the destination
exists. Only explicit `overwrite:true` permits replacement. No-overwrite uses
native atomic rename (`renameat2` on Linux, `renameatx_np` on macOS), never an
exists-check followed by an overwriting rename. An unsupported platform/filesystem
returns `atomic_move_unavailable`. Parents must exist; cross-filesystem moves can
fail. Both endpoints must satisfy policy; there is no copy/delete fallback.

Deletion **always requires a worker preview**:

```json
{"type":"req","id":"preview-1","method":"node.fs.delete.preview","params":{"nodeId":"node-id","path":"results/note.txt"}}
```

The preview returns the canonical `path`, its `stat`, immediate `childCount`,
opaque `childrenDigest`, deletion `candidateCount` (including the target), an
opaque `confirmationToken`, and `expiresAtMs`. Tokens are worker-owned, one-use,
expire after five minutes, and do not survive a service restart. Keep tokens
private to the trusted backend; do not reconstruct or edit them.

Send that token with `confirm` **exactly equal to the original caller's `path`
string**, not an expanded equivalent:

```json
{"type":"req","id":"delete-1","method":"node.fs.delete","params":{"nodeId":"node-id","path":"results/note.txt","confirm":"results/note.txt","confirmationToken":"TOKEN_FROM_PREVIEW_RESPONSE"}}
```

The default preview permits only a file or **empty directory** to be deleted.
For a nonempty tree, explicitly request `recursive:true` on the preview; there
is no recursive flag on deletion. The token binds the target's inode/revision
and all admitted child candidates, including hidden entries. Added, removed,
replaced or modified candidates cause `stale_preview`; re-preview and obtain
fresh operator confirmation rather than retrying the old token. Recursive
deletion unlinks child symlinks without following their targets. Previews are
limited to 10,000 bound entries, 64 levels, and an 8 MiB candidate-storage budget;
oversized previews return `preview_too_large` rather than pruning candidates.
The service retains at most 128 previews, 20,000 total bound entries, and a
16 MiB total candidate-storage budget. Allowed roots cannot be deleted or moved.

Entries are atomically captured under temporary `.lemon-delete-*` /
`.lemon-move-*` names before destructive identity checks. A concurrent local
writer can cause partial recursive deletion; if it also occupies an original
name during rollback, a captured entry may remain under its temporary name
rather than overwriting the new entry. Inspect and reconcile such failures.
Request errors contain bounded classifications, not file content or raw OS exceptions.
The serialized helper has a 25-second request deadline. An in-flight timeout or
helper interruption returns `filesystem_outcome_unknown`, closes the helper,
and invalidates its tokens. A lost/timeout mutation response is not proof that
it did not happen; inspect destination state before issuing another mutation.
Never automatically retry an uncertain mutation. The service also bounds pinned
policy/root descriptors (128 each); exhaustion returns `filesystem_busy`, not an
unbounded descriptor cache.

## Native processes

Use `node.process.run` for automated destination-native commands and probes,
not an interactive terminal. It launches a literal executable/argv with separate
stdout/stderr pipes and exact decoded stdin bytes followed by EOF. No stream is
a TTY. There is **no shell interpolation, PTY, SSH, or named-node fallback**.
Interactive user terminals continue to use `node.shell.*` unchanged.
Python 3 is required on the destination. Native processes run with the worker
OS account's permissions and destination-local credentials: root admission of
cwd is not an OS sandbox.

All three methods are admin-scoped and asynchronous. `run` awaits the bounded
final receipt; get is strictly read-only, and cancel is a mutation.

| Method | Exact request fields | Result |
| --- | --- | --- |
| `node.process.run` | `nodeId, processId, cwd, argv, stdinBase64, timeoutMs, maxOutputBytes` (all required) | Seven-field process receipt below |
| `node.process.get` | `nodeId, processId` | Same receipt, or successful strict absence `state:"not_found"` |
| `node.process.cancel` | `nodeId, processId` | Same receipt; missing ID is durably tombstoned before acknowledgment |

Choose and retain a fixed `processId` **before the first intent**. For example:

```json
{"type":"req","id":"native-run-1","method":"node.process.run","params":{"nodeId":"node-id","processId":"probe:fixed-1","cwd":".","argv":["python3","-c","import sys; data=sys.stdin.buffer.read(); sys.stdout.buffer.write(data); sys.stderr.write('diagnostic\\n')"],"stdinBase64":"SGVsbG8K","timeoutMs":30000,"maxOutputBytes":1048576}}
```

If this execution really observes exit 0 and captures those bytes, its success
payload is exactly:

```json
{"processId":"probe:fixed-1","nodeId":"node-id","state":"completed","exitCode":0,"stdoutBase64":"SGVsbG8K","stderrBase64":"ZGlhZ25vc3RpYwo=","outputTruncated":false}
```

There is no `env`, shell command string, TTY flag, or client-supplied admission
option. The control plane validates before dispatch and the worker independently
validates again:

- `processId`: 1–128 ASCII letters, digits, `_`, `:`, or `-`.
- `argv`: 1–128 UTF-8 strings, no NUL; each and their combined total are at most
  131,072 bytes. `argv[0]` is a nonempty literal executable (PATH name or
  absolute path). Later empty arguments, Unicode, spaces and quotes are preserved,
  never split or expanded. Missing executable, permission failure and OS `E2BIG`
  are errors, not fabricated process exit receipts.
- `cwd`: nonempty UTF-8, at most 4096 bytes, no NUL or `..` components. The
  destination pins the admitted directory descriptor under home and explicitly
  configured `--allowed-root` roots, rejecting traversal and symlink escapes.
- `stdinBase64`: valid standard base64, decoded at most 1,048,576 bytes. Empty
  string is valid and closes stdin without sending bytes.
- `timeoutMs`: integer 1000–1,800,000, inclusive (30 minutes). The broker deadline
  is this value plus 5000 ms, and the control-plane await allows 1000 ms more.
  Get and cancel use the normal 30-second broker deadline.
- `maxOutputBytes`: integer 1–1,048,576, inclusive, bounding **combined** captured
  stdout and stderr bytes, not a separate allowance per stream. Also respect the
  connection's negotiated JSON payload cap and base64/protocol overhead.

The current actual authenticated node must advertise version 1 for
`node.process.run`, `.get` and `.cancel`. The control plane resolves the exact
durable ID and pins its live connection PID/generation; registry admission
checks the actual descriptors before delivery. Caller fields cannot override
those internal options, and raw `node.invoke` rejects `node.process.*`.
The broker supplies `nodeGeneration` from its authenticated registry record,
not from request arguments.

### Receipt meaning and reconciliation

Every successful result has exactly
`{processId,nodeId,state,exitCode,stdoutBase64,stderrBase64,outputTruncated}`.
States are `running`, `completed`, `cancelled`, or `outcome_unknown`; get alone
also permits `not_found`. `exitCode` is an integer only when an OS exit was
actually observed, otherwise null. Output base64 strings are actual captured
bytes: `""` means known zero bytes. Unavailable outputs are **null**, never
invented empty strings, and set `outputTruncated:true`.
A `completed` receipt must have an actually observed integer `exitCode`,
including after restart when captured outputs are no longer available.

A running, unknown, or not-found receipt has null exit and both outputs null.
Cancellation before execution likewise returns `cancelled`, null exit/outputs
and `outputTruncated:true`. Timeout or output overflow cancels and cleans up the
process group/descendants where supported; any returned exit code must still
come from an actual observed termination. Worker restart preserves known receipt
state and exit metadata, not raw output: output becomes null/truncated. An
interrupted active receipt becomes `outcome_unknown` and never relaunches.
Each execution signals its group at most once successfully; output draining and
final cleanup do not repeatedly signal the stopped group's numeric identifier.
A first group-stop permission failure remains an error, never a successful
cancelled receipt, and still releases the helper's owned descriptors.

If a response is lost, a controller times out, or an error says the mutation
outcome may be unknown, **never automatically redispatch run**, even with a new
ID. Retain the original node/ID and query it:

```json
{"type":"req","id":"native-get-1","method":"node.process.get","params":{"nodeId":"node-id","processId":"probe:fixed-1"}}
```

Get cannot launch or replay work and can read a predecessor generation's receipt.
Only an actual successful strict destination Store read finding no receipt may
return `not_found`. Offline, transport, Store and lookup failures remain errors:
they are neither absence nor proof that execution stopped. A broker failure
does not synthesize an `outcome_unknown` success receipt; only the owning
destination receipt can attest its state. Keep uncertainty until reconciled.

The destination service permits 16 active runs and 1,000 retained fixed IDs,
including automatic inspections/probes and cancellation tombstones. Spent IDs
never expire or become runnable again. At capacity, `process_receipt_limit`
rejects new admission without execution; operators need a destination with
available capacity, not a spent-ID deletion/reuse workaround. Output is a
separate volatile cache of at most 16 completed receipts for 24 hours: losing
those bytes does not erase known status/exit or permit replay.

### Cancellation races

```json
{"type":"req","id":"native-cancel-1","method":"node.process.cancel","params":{"nodeId":"node-id","processId":"probe:fixed-1"}}
```

For an absent ID, cancel atomically writes a durable node-scoped cancelled
tombstone **before replying**. A racing later run using that ID cannot start;
there is no cancellation-as-best-effort existence check. Active cancellation
requires the original owning authenticated node/session generation/invocation,
so a replacement worker cannot cancel its predecessor's run. A terminal race
returns the actual owning receipt, not an invented successful kill. If cancel's
reply is uncertain, reconcile the same fixed ID with get rather than replaying
execution.

### Credential privacy

Only the authenticated requester's awaited response receives output; there are
no process-output events. Argv, stdin, stdout/stderr and credentials must never
enter general Bus events, model messages, logs or durable process receipt content.
Persistent receipts retain only bounded admission/terminal metadata and a private
intent binding; they do not store raw argv, stdin or output and never expose the
private binding. Keep credential-bearing input/output in the trusted backend and
use `wss://` or an explicitly trusted encrypted overlay. Do not embed credentials
in executable arguments or copy raw command results into product diagnostics.

## Write-only encrypted secrets

These operations delegate to the destination's existing `LemonCore.Secrets`
encrypted store and master-key providers. Configure the master key **on the
destination**; no controller master key is forwarded. See
[Secrets and Keychain](../security/secrets-and-keychain.md).

| Method | Request fields besides `nodeId` | Successful payload |
| --- | --- | --- |
| `node.secrets.set` | `name, value, [operationId]` | `{name, set:true}`; with an ID, also `{operationId, status:"applied", currentBindingMatches:true}` |
| `node.secrets.list` | none | `{names, limit:500, truncated}` |
| `node.secrets.delete` | `name` | `{name, deleted:true}` |
| `node.secrets.receipt` | `operationId` | `{nodeId, operationId, status:"applied"\|"not_found", name:string\|null, currentBindingMatches}` |

Names are nonempty UTF-8 strings, at most 256 bytes, with no NUL; the owning
secret API trims names. Values are strings at most 1 MiB. `set` replaces an
existing name; `delete` is idempotent for a missing name. `list` returns only
names from the encrypted store's default owner, sorted and bounded to 500; it
does not enumerate environment variables or external secret sources. Expired
entries are excluded from reads and lists. There is **no `node.secrets.get`** and
no response returns plaintext, ciphertext, nonces, salts, private fingerprints,
or provider metadata.
Runtime providers can still resolve a stored secret locally using existing APIs.

### Reconciling a secret installation

Choose and retain an `operationId` **before** sending `node.secrets.set`. It must
be 1–128 ASCII letters, digits, `_`, `:`, or `-`. For example:

```json
{"type":"req","id":"secret-set","method":"node.secrets.set","params":{"nodeId":"node-id","name":"integration/token","value":"VALUE_FROM_PRIVATE_BACKEND","operationId":"install:token-1"}}
```

A fixed-ID success includes `operationId`, `status:"applied"`, and
`currentBindingMatches:true`. If the response is lost or the mutation outcome
is unknown, **do not blindly send another set**. Query the original node/ID:

```json
{"type":"req","id":"secret-proof","method":"node.secrets.receipt","params":{"nodeId":"node-id","operationId":"install:token-1"}}
```

The read-only query returns exactly:

```json
{"nodeId":"node-id","operationId":"install:token-1","status":"applied","name":"integration/token","currentBindingMatches":true}
```

`applied` proves that this exact operation was accepted in the destination vault;
it does not attest provider authentication, credential validity, or bot readiness.
`currentBindingMatches` is true only while the installed encrypted revision remains
active and unexpired. An ordinary replacement, deletion, expiry, or key rotation
can make it false without erasing the historical proof. A deleted secret leaves
private receipt-only metadata, invisible to secret lists and value resolution.
`not_found` returns `name:null` and `currentBindingMatches:false`; query errors or
an offline node are **not** `not_found`.

Repeating the original set with the same ID and exact intent returns its success
without encrypting or writing again, but only while its binding still matches.
A different name/value or changed binding returns `secret_operation_conflict`,
never a replacement or replay. Operation IDs are scoped to the destination's
secret owner and authenticated durable node identity, not caller-controlled RPC
fields. Receipts contain no plaintext or public value digest; queries neither
decrypt secrets nor change usage metadata.

The vault retains at most 128 receipts per secret name, including deleted names.
A new operation at capacity returns `secret_receipt_capacity` before replacing the
secret; existing proof is never silently pruned. Sets without `operationId`
retain their original response shape and do not supply reconciliation proof.

Names under `lemon_bot/invocations/<runId>` are reserved private invocation proofs.
Their fixed `operationId` must equal `<runId>`, even when the supplied name has
surrounding whitespace that the vault trims. Pending follow-up provisioning uses
the owning lineage's sealed exact destination, connection PID and credential
generation. Only a strictly absent owning row permits initial root provisioning;
completed/nonpending or mismatched follow-ups cannot be treated as new roots.
Both cases atomically require the destination's native privacy protocol and the
inspected session before any value is sent. A reconnect or same-PID credential
generation change fails before dispatch. These are server-side admission checks,
not client boolean flags. Other secret names keep the ordinary behavior above.

A vault success is rechecked after the awaited reply before a private-proof
success is returned. The same original PID/generation and current native privacy
capability must remain valid, and pending ownership/configuration/policy must
still match. A changed check returns `private_proof_acknowledgement_changed`
with `retrySafe:false` and `mutationMayHaveApplied:true`, not a positive binding
acknowledgement: do not replay the set. A disappeared follow-up owner never
falls back to fresh-root provisioning. Initial-root proof installation alone
does not authorize model execution; actual root admission performs those checks.


Do not log requests, values, or file transfer bodies in client/backend tracing.
The destination facade emits a bounded content-free audit/telemetry event
`[:coding_agent, :execution_node, :host_io]` with measurement `count:1` and only
`method` plus safe `outcome`. Paths, secret names/values, file bytes, raw arguments,
and raw results are not included. This audit is telemetry, not a separate durable
secret history database.
