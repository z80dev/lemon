# Execution-node files and secrets

These control-plane `/ws` methods operate on the **destination execution node**,
not on the controller's filesystem. Use the enrolled machine's durable `nodeId`.
The destination must be online. Requests use the normal authenticated `req` /
`res` protocol; a successful response's `payload` contains the shapes below.
Handlers dispatch asynchronously so other socket traffic can continue.

`node.host.info` requires operator `read`. **Every `node.fs.*` and
`node.secrets.*` method requires operator `admin`, including reads and lists.**
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

This is **path admission, not an OS sandbox**. It cannot prevent another local
process from changing directories or symlinks between admission and a filesystem
operation. Host shells, tools and extensions execute with the worker OS account's
permissions. Use a dedicated OS account/container and OS permissions for
untrusted workloads. Bots on the same machine share that account's files and
credentials; profile identity does not isolate this store.

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
  "lemonVersion": "0.1.0",
  "defaultCwd": "/srv/project",
  "user": "lemon"
}
```

The example illustrates fields, not fixed values. Metrics are obtained from the
actual destination: Linux `/proc`, macOS `sysctl` / `vm_stat`, and POSIX `df` for
the filesystem containing `defaultCwd`. `memFreeBytes` means genuinely free
pages, not estimated reclaimable/available memory. `arch` is the BEAM system
architecture string; `lemonVersion` is the installed coding-agent application
version. Unavailable measurements are `null`, **never invented zeroes**.
Read-only host metadata remains available even if cwd is outside file roots.

## File operations

All requests include `nodeId`. Optional fields are in brackets here; send normal
JSON properties without brackets.

| Method | Request fields besides `nodeId` | Successful payload |
| --- | --- | --- |
| `node.fs.list` | `path, [showHidden=false]` | `{path, entries, limit:500, truncated}` |
| `node.fs.stat` | `path` | `{path, type, size, mtimeMs, mode, mime}` |
| `node.fs.read` | `path, [offset=0, length=1048576]` | `{path, dataBase64, offset, length, size, mime, eof}` |
| `node.fs.write` | `path, dataBase64, [offset=0, truncate=true, mkdirs=false]` | `{path, offset, bytesWritten, size}` |
| `node.fs.mkdir` | `path` | `{path, created:true}` |
| `node.fs.move` | `path, destination` | `{path, destination, moved:true}` |
| `node.fs.delete` | `path, confirm` | `{path, deleted:true}` |

Directory entries include `name` plus the stat fields. Listing uses `lstat`:
symlink entries show `type:"symlink"`, with no link target disclosure or
recursive walk. An entry that disappears or becomes unreadable during listing
has `{name,error}` instead. Entries are sorted by name; dot-prefixed names are
hidden unless `showHidden:true`. Output stops at 500 entries and reports
`truncated:true` when more visible entries exist. There is no pagination cursor.
`type` follows filesystem types such as `regular`, `directory`, and `symlink`.
`size` is bytes, `mtimeMs` is Unix modification time in milliseconds (filesystem
seconds precision), `mode` is the integer filesystem mode, and MIME is inferred
from the filename, not a content inspection or security verdict.

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

```json
{"type":"req","id":"upload-1","method":"node.fs.write","params":{"nodeId":"node-id","path":"results/note.txt","dataBase64":"SGVsbG8g","offset":0,"truncate":true,"mkdirs":true}}
{"type":"req","id":"upload-2","method":"node.fs.write","params":{"nodeId":"node-id","path":"results/note.txt","dataBase64":"d29ybGQ=","offset":6,"truncate":true}}
{"type":"req","id":"read-1","method":"node.fs.read","params":{"nodeId":"node-id","path":"results/note.txt","offset":0,"length":6}}
```

The first read yields decoded `Hello `, `size:11`, `length:6`, `eof:false`.
Read the next chunk at offset 6 to receive `world` and `eof:true`. Clients must
also respect the connection's negotiated JSON payload cap: base64 requires
approximately 4/3 of the decoded size plus protocol overhead.

`mkdir` creates parent directories and is idempotent for an existing directory.
`move` uses the destination OS rename operation: parents must exist, overwrite
behavior is the OS's rename behavior, and cross-filesystem moves can fail. It is
not a copy/delete fallback. Both endpoints must satisfy policy.

For deletion, `confirm` is mandatory and must **exactly equal the caller's
`path` string**, not an expanded equivalent:

```json
{"type":"req","id":"delete-1","method":"node.fs.delete","params":{"nodeId":"node-id","path":"results/note.txt","confirm":"results/note.txt"}}
```

Deletion removes a file or an **empty directory**; it is not recursive. Allowed
roots cannot be deleted or moved. Request errors contain bounded classifications,
not file content or raw operating-system exception strings. A lost/timeout
mutation response is not proof that the mutation did not happen; inspect the
destination state before deciding whether to issue another mutation.

## Write-only encrypted secrets

These operations delegate to the destination's existing `LemonCore.Secrets`
encrypted store and master-key providers. Configure the master key **on the
destination**; no controller master key is forwarded. See
[Secrets and Keychain](../security/secrets-and-keychain.md).

| Method | Request fields besides `nodeId` | Successful payload |
| --- | --- | --- |
| `node.secrets.set` | `name, value` | `{name, set:true}` |
| `node.secrets.list` | none | `{names, limit:500, truncated}` |
| `node.secrets.delete` | `name` | `{name, deleted:true}` |

Names are nonempty UTF-8 strings, at most 256 bytes, with no NUL; the owning
secret API trims names. Values are strings at most 1 MiB. `set` replaces an
existing name; `delete` is idempotent for a missing name. `list` returns only
names from the encrypted store's default owner, sorted and bounded to 500; it
does not enumerate environment variables or external secret sources. Expired
entries are removed by the owning API. There is **no `node.secrets.get`** and
no response returns plaintext, ciphertext, nonces, salts, or provider metadata.
Runtime providers can still resolve a stored secret locally using existing APIs.

Do not log requests, values, or file transfer bodies in client/backend tracing.
The destination facade emits a bounded content-free audit/telemetry event
`[:coding_agent, :execution_node, :host_io]` with measurement `count:1` and only
`method` plus safe `outcome`. Paths, secret names/values, file bytes, raw arguments,
and raw results are not included. This audit is telemetry, not a separate durable
secret history database.
