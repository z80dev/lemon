# File and Search Tools

The coding agent's file tools are `read`, `write`, `edit`, `patch`, `ls`, and
the search tools `grep`, `find` and `ast_grep`. This page covers read
selectors, SQLite views and search paging; snapshot-anchored edits and rich
reads (archives, PDFs, notebooks, images) are described in the
[coding_agent README](../../apps/coding_agent/README.md#built-in-tools).

## Session internal URLs

`local://name` stores a scratch file beneath the session artifact directory.
Use it with `read`, `write`, or as a whole shell word in `bash`. Names are single
path segments; traversal and symlinks are rejected. Scratch files are per-session,
not shared automatically with child sessions.

`read proc://` lists up to 200 processes owned by the current session.
`read proc://<id>` returns status and recent output without consuming the
`bash_output` cursor. `write proc://<id>` sends `content` verbatim to stdin;
`write proc://<id>/kill` sends SIGTERM with the normal kill-process fallback.
Foreign process IDs are not accessible.

`read issue://42` and `read pr://42` resolve the GitHub repository from the cwd's
git `origin` remote (HTTPS or SSH). Explicit forms such as
`issue://owner/repo/42` and `pr://owner/repo/42` work outside a checkout.
Lemon prefers an installed, authenticated `gh` CLI; if unavailable or unsuccessful,
it uses public GitHub REST without handling tokens itself. Issue/PR descriptions
include the first 100 comments. `pr://42/diff` lists files with zero-based indexes,
`pr://42/diff/0` shows one patch, and `pr://42/diff/all` shows all returned patches.
Diff enumeration is capped at 1000 files; GitHub may omit large or binary patches.
Views are capped at 50 KB and marked untrusted.

`read history://<task_id>` shows the owned child's assignment, status, up to ten
recent visible progress updates, and final visible answer retained by TaskStore.
It is a concise transcript, not raw session events: hidden reasoning, tool-call
internals and foreign tasks are excluded. History is capped at 12,000 Unicode
characters and tagged untrusted. Expired TaskStore entries are unavailable.

## Read line selectors

`read` pages text with `offset`/`limit`, or with a selector appended to `path`:

| Selector | Meaning |
| --- | --- |
| `file:50-80` | lines 50 through 80, plus 1 preceding / 3 following context lines |
| `file:50+20` | 20 lines starting at line 50, plus the same context |
| `file:5-16,960-973` | exact disjoint line windows |
| `file:5,19,59` or `file:5,19-25,59+2` | exact individual lines, ranges, or counts in one read |
| `file:50` or `file:50-` | from line 50 to the end (still capped at 2000 lines / 50 KB) |
| `file:-30` | the last 30 lines |
| `file:raw`, `file:50-80:raw`, `file:raw:50-80` | unnumbered text without the snapshot header |

Selectors also work on archive members (`bundle.zip:src/a.ex:10-20`), rendered
formats such as PDFs and notebooks, and internal references
(`artifact://<id>:100+50`). They only apply when the literal path does not
exist, so a file really named `notes:12` is still read as-is. A selector cannot
be combined with `offset`/`limit`. `:raw` output omits the snapshot tag, so use
a numbered read before a snapshot-anchored `edit`.

A comma list is sorted and overlapping or adjacent windows are merged. Each
window keeps its original line numbers, with a standalone `…` separator between
windows and only one snapshot header for editable files. Comma-list numbers
select individual lines (unlike the standalone open-ended `:50` selector).
Comma windows must be bounded; tail and open-ended forms cannot be mixed into
a list. All windows share the 2000-line / 50 KB output budget.

Context for a single bounded range is clamped to the source boundaries. Raw
selectors (`:raw:50-80` or `:50-80:raw`) remain exact, without context, line
numbers, or a snapshot header. Raw comma lists also stay exact and retain the
`…` separators. `offset`/`limit`, open-ended and tail selectors do not add context.

## Merge conflicts

`read path:conflicts` indexes local Git conflict regions as `#N Lx-Ly` with
compact ours/theirs previews. Standard and diff3 (`|||||||` base) markers are
supported. Existing literal filenames ending in `:conflicts` still take precedence.
Conflict indexing requires a session id, UTF-8 local files up to 4 MiB, and cannot
be combined with other selectors or ACP client buffers.

Resolve one region with `write` using `path: "conflict://N"` and a replacement
`content` body. Standalone body lines `@ours`, `@theirs`, `@base`, and `@both`
expand to the original side text (`@both` concatenates ours then theirs;
`@base` is empty for ordinary two-way conflicts). Other body text is literal.
Only the marker region is replaced; surrounding bytes, BOM and line endings are
preserved through the normal write pipeline, including mutation locks,
checkpoints, formatting and diagnostics.

Ids belong to the calling session. Any file-content change, including resolving
one region, invalidates **all** ids for that file: re-read `path:conflicts`
before resolving another region. Foreign, unknown, malformed and stale ids are
rejected instead of falling back to ordinary filesystem writes.

## Structural code summaries

A bare `read` of a recognized source-code file with at least 300 lines and at
most 2 MiB returns a structural outline. A conservative indentation/brace scanner
keeps declarations, continued signatures, and top-level lines; strings and
comments do not contribute brace depth. Function bodies are replaced by
`… [lines a-b elided]` markers using original line numbers. This is an outline,
not a parsed AST: re-read the marked source ranges before changing code.

The header explicitly labels the view partial and immutable, with no snapshot
tag. The footer gives concrete `path:a-b` examples for omitted ranges; an explicit
numbered range read supplies the normal editable snapshot. `write` refuses both
summary elision markers and the summary header/footer on existing targets.

Any path selector (including `:raw`), explicit `offset`/`limit`, or
`"summary": false` bypasses outlining. Tool hosts can set `structural_summary: false`
option to disable it by default. Full-text reads still obey the usual 2000-line /
50 KB budget. Non-code, smaller, and larger-than-2-MiB files retain normal read
behavior; if there is nothing to elide, the normal view is returned. The outline
also applies to authoritative ACP unsaved buffers, not their on-disk contents.

## Anchored edit recovery and formatting

Session-scoped anchored edits can recover an older snapshot tag after unrelated
changes. Every referenced original line range must still occur byte-for-byte at
exactly one position in the current file; changed, ambiguous, unknown, or evicted
anchors retain the snapshot-mismatch error without writing. Text replacements
still reject changes since the last read. The session retains up to eight
snapshots per path, each at most 256 KiB and 10,000 lines; larger files still
support fresh-tag edits, but not historical recovery. This does not restrict
edits to previously displayed lines.

Local `write`, `edit`, and `patch` accept `"format": true` (default false, unless
enabled in tool options) to run an available formatter after writing. An explicit
false overrides that default. Results report `formatted` and any `format_error`;
formatter failure does not undo the write. Edit headers and patch per-file
`snapshot` tags describe the post-format file, so they can be used directly for
the next anchored edit. ACP writes retain client-managed formatting behavior.

## Patch hunk matching

Patch hunk context must identify a unique location. Exact matches take precedence;
on an exact miss, `patch` tolerates indentation, horizontal whitespace, and smart
quote/dash differences using the same normalization as text `edit`. Multiple
normalized matches are rejected. Unchanged context keeps its original text.

## Safe overwrites

`write` refuses to overwrite an existing file with content containing a read
continuation, long-line budget notice, selector-elision marker, or structural summary.
Re-read the omitted range or use `edit` instead. New files are not subject to this
check. Existing UTF-8 BOMs and dominant
CRLF line endings are preserved when incoming text omits them; explicitly supplied
CRLF text is left intact. The same safeguards apply to ACP writes when the prior
contents are available. Local overwrite format detection samples only the first
64 KiB, keeping memory bounded even when replacing very large files.

Local `patch` updates, deletes, and move sources check the session's last read
against the current raw file bytes before any patch writes. If the file changed,
re-read it before applying the patch. Files not previously read in the session
can still be patched.

## Archive member writes

`write bundle.zip:inner/file.txt` replaces or adds one UTF-8 member. ZIP, TAR,
`.tar.gz` and `.tgz` containers are supported, including new containers. Existing
literal selector-shaped files take precedence. Members must be relative,
slash-separated paths without empty, `.` or `..` segments; directories and links
cannot be overwritten. Existing archives use the normal size, mutation lock,
checkpoint, symlink and plan-mode guards. Replacing a member with truncated-read
output is refused. A sibling temporary file is renamed over the archive only
after the full replacement is ready.

Unchanged ZIP members retain their uncompressed bytes and file metadata (ZIP
compression/layout may change). Unrelated TAR headers, data, links and extension
records remain byte-identical; gzip containers are recompressed. The replaced
TAR member retains its mode, owner and timestamp.


## SQLite databases

A `.db`, `.db3`, `.sqlite` or `.sqlite3` file with the SQLite header is opened
read-only (`SQLITE_OPEN_READONLY` and `PRAGMA query_only`):

```text
app.db                                   tables and views with row counts
app.db:users                             CREATE statement + 5 sample rows
app.db:users?limit=20&offset=40          rows 41-60 (limit ≤ 500)
app.db:users?where=age>30&order=name     filtered, ordered page
app.db:users:42                          one row by primary key (else rowid)
app.db?q=SELECT name FROM users LIMIT 5  one read-only query (≤ 1000 rows)
```

`where`, `order` and `q` reject comments, multiple statements and
write/attach/pragma/transaction keywords; queries are interrupted after 10
seconds. Database output is ordinary numbered text, so `offset`/`limit` page
long results.

`write app.db:users` inserts a row from a strict JSON object. Use
`write app.db:users:42` to update fields by single-column primary key (including
text keys), or rowid for tables without a primary key. Empty/whitespace content
on a keyed selector deletes that row. `{}` inserts default values but is not a
valid update. Composite primary keys and unavailable rowid fallbacks are refused.
Values must be JSON scalars; column names are checked against `pragma_table_info`
and SQL values are bound parameters. Database files must already exist; writes
never create one. Query parameters are not accepted for writes. Connections use
a 3-second busy timeout and physical database paths take the normal mutation lock,
checkpoint, symlink and plan-mode guards. Existing literal selector-shaped files
take precedence over SQLite interpretation.

## grep paging and ignore rules

`grep` sorts matches by path and line before applying `skip` / `max_results`
(default 100), so pages are deterministic while files are unchanged. Ripgrep
returns the total match count; the Elixir fallback stops after `skip + max_results`
matches and reports an "at least" count with `details.incomplete: true` when
that limit is reached. A final page may therefore be empty. The notice and
`details.next_skip` give the next `skip` value:

```json
{"pattern": "TODO", "max_results": 50, "skip": 50}
```

`output_mode` defaults to `"content"`. `"files"` returns each matching path once;
`"count"` returns per-file matching-line counts and the total across searched files
(also in `details.counts` and `details.match_count`). In these modes `skip` and
`max_results` page files, not individual matches. Count mode scans all files within
the fallback's deadline and per-file byte bound, rather than stopping at a page.
Patterns containing a literal newline or `\n` enable multiline search (`rg -U` or
whole-file fallback matching); results identify the start line of each matching span.

Both `grep` and `find` accept semicolon-separated `path` roots, such as
`"src; test"` (whitespace/empty entries are ignored). Existing roots are searched
and merged deterministically, with duplicate results removed before the result
limit/page is applied. Missing roots appear in `details.missing_paths` and a
notice; the call fails only when no root exists (other access/type errors still
fail). Multi-root grep paths are relative to cwd, so same-name files stay distinct.

Long grep lines show a roughly 500-character window centered on the first match,
with `...` on each cut side and `[col N]` giving the original 1-based character
column. Use `read` on the reported file/line for the complete text.

Hidden files and files ignored by `.gitignore`/`.ignore` are skipped by default,
with ripgrep or the Elixir fallback (which uses `git check-ignore` inside a work
tree). Pass `"hidden": true` and/or `"no_ignore": true` to include them. `find`
has the same `hidden`/`no_ignore` switches.

Lookaround and backreferences automatically use ripgrep's PCRE2 engine when
available (capability is probed once and cached). Without PCRE2, these patterns
return an error identifying the unsupported construct and Rust regex engine;
literal searches never require PCRE2. If ripgrep reports errors after finding
matches, those matches are preserved with the first diagnostic in a `warnings`
line and `details.warnings`; errors without matches still fail.

The Elixir fallback has a 30-second deadline, including file enumeration and
matching. It searches only the leading 4 MiB of each file and reports the number
of visited files with omitted tails in `details.skipped_oversized`. It skips
binary and invalid UTF-8 files and stops scanning when the requested page is
filled; use `next_skip` to continue.

## Find ordering and path globs

`find` collects and deduplicates the full candidate set across roots, sorts it,
then applies `max_results`. `sort: "path"` remains the default, preserving the
existing alphabetical/stable discovery contract. Use `sort: "mtime"` to surface
recently modified entries first; equal timestamps are ordered by path.

Patterns without `/` match basenames recursively. Patterns containing `/`, such
as `lib/*.ex`, match path segments at any depth (including `nested/lib/a.ex`, but
not `lib/deep/a.ex`); use `**` for recursive segments. The fd backend uses
`--full-path` and a recursive prefix to match the same set as the Elixir fallback.
Both backends reject scopes exceeding 100,000 matching candidates with a narrowing
hint instead of sorting a traversal-order subset. The fd safety ceiling is
independent of `max_results`.

## Structural search limits

`ast_grep` refuses a scope with more than `max_files` files (default 1000) before
starting the CLI or writing. Narrow `paths` or explicitly raise the cap. Directory
enumeration skips hidden and ignored paths and does not follow directory
symlinks; explicit files remain eligible. The cap counts candidate files, not
just matching files, across the deduplicated scope.

Each file is searched independently under the call's shared CLI timeout. A file's
parse/CLI failure does not discard successful files: `details.parse_errors`
contains the first 20 failures and `parse_errors_total` counts all failures.
If every file fails, the tool still returns an error. Match counts and replacement
previews exclude failed files, which are never rewritten.

Large JSONL match results retain their complete spill file. When session artifact
storage is available, the notice uses its `artifact://` handle and
`details.artifact_uri` exposes it; `full_output_path` retains the backing path.

