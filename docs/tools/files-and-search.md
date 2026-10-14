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
| `file:50-80` | lines 50 through 80 |
| `file:50+20` | 20 lines starting at line 50 |
| `file:50` or `file:50-` | from line 50 to the end (still capped at 2000 lines / 50 KB) |
| `file:-30` | the last 30 lines |
| `file:raw`, `file:50-80:raw`, `file:raw:50-80` | unnumbered text without the snapshot header |

Selectors also work on archive members (`bundle.zip:src/a.ex:10-20`), rendered
formats such as PDFs and notebooks, and internal references
(`artifact://<id>:100+50`). They only apply when the literal path does not
exist, so a file really named `notes:12` is still read as-is. A selector cannot
be combined with `offset`/`limit`. `:raw` output omits the snapshot tag, so use
a numbered read before a snapshot-anchored `edit`.

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

`grep` returns the total match count and at most `max_results` matches
(default 100). When more exist, the notice and `details.next_skip` give the
`skip` value for the next page:

```json
{"pattern": "TODO", "max_results": 50, "skip": 50}
```

Hidden files and files ignored by `.gitignore`/`.ignore` are skipped by default,
with ripgrep or the Elixir fallback (which uses `git check-ignore` inside a work
tree). Pass `"hidden": true` and/or `"no_ignore": true` to include them. `find`
has the same `hidden`/`no_ignore` switches.
