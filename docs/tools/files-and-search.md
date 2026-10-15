# File and Search Tools

The coding agent's file tools are `read`, `write`, `edit`, `patch`, `ls`, and
the search tools `grep`, `find` and `ast_grep`. This page covers read
selectors, SQLite views and search paging; snapshot-anchored edits and rich
reads (archives, PDFs, notebooks, images) are described in the
[coding_agent README](../../apps/coding_agent/README.md#built-in-tools).

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

## Patch hunk matching

Patch hunk context must identify a unique location. Exact matches take precedence;
on an exact miss, `patch` tolerates indentation, horizontal whitespace, and smart
quote/dash differences using the same normalization as text `edit`. Multiple
normalized matches are rejected. Unchanged context keeps its original text.

## Safe overwrites

`write` refuses to overwrite an existing file with content containing a read
continuation, long-line budget notice, or standalone `…` selector-elision marker.
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
long results. Writing to databases is not supported.

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
