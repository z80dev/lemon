# Manifest command

Repair the dependency-free `manifestctl` binary. Keep argument handling, manifest processing, and process I/O in separate files. The supported interface is the command line (no public Rust library API is required).

```
Usage: manifestctl [--kind KIND] [--min-size N] [--sort name|size] [--total] [FILE|-]
```
This exact line plus a newline is the entire successful `--help` or `-h` output. Help must be the sole argument; otherwise emit `error: help must be used alone`. Help exits 0. Successful transforms exit 0; all other failures below exit 2, emit exactly one diagnostic line on stderr (ending in newline), and leave stdout empty. Normal success leaves stderr empty.

## Arguments
No path, or the path `-`, reads UTF-8 stdin; otherwise read the named UTF-8 file. Options may occur before or after the path. `--` ends option parsing, so following arguments are paths even if they begin with `-`. At most one path is allowed. Options do not support `--name=value` or short aliases other than `-h`.

`--kind KIND` retains records whose kind equals KIND, case sensitively. KIND uses the identifier syntax below. `--min-size N` retains size >= N, where N is one or more ASCII decimal digits fitting u64 (leading zeros are accepted). `--sort name` sorts by ascending ASCII name; `--sort size` sorts ascending numeric size, breaking ties by ascending name. Without `--sort`, preserve input order. `--total` appends the summary described below. Filters combine with AND. Each option may occur only once, including `--total`.

Parse arguments left to right before opening input. If a value-taking option is duplicated, report the duplicate before considering its value. A value is the very next argument, even if it begins with `-`; it is missing only when there is no next argument. Recognize help only before `--`; if any recognized help flag occurs, help-alone handling takes priority over other argument errors. A `--help` after `--` is a path, not help.

Exact argument diagnostics:
- `error: unknown option ARG` for an unrecognized argument beginning with `-` (except `-` itself).
- `error: duplicate option OPTION` for repeated recognized options.
- `error: missing value for OPTION` when its value is absent.
- `error: invalid value for OPTION` for an invalid KIND, N, or sort mode.
- `error: multiple input paths` for a second positional path.
- `error: help must be used alone` as above.
All read failures, including non-UTF-8 data and nonexistent files, produce `error: cannot read input` (no platform-specific details).

## Manifest grammar and output
Each nonblank, noncomment line has exactly three `|`-separated fields: `name|kind|size`. Line numbers start at 1 and count comments and blank lines. Split on LF, accepting CRLF too. Strip ASCII space, tab, and CR at both ends of each line and field. Ignore empty lines and lines whose first remaining character is `#`; there are no inline comments. A name or kind is a nonempty ASCII identifier consisting only of letters, digits, `_`, `.`, and `-` (digits may start it). Size uses the same decimal u64 rules as `--min-size`. Names must be unique across the whole input, even for records excluded by filters.

Validate the entire input before producing output or filtering. On the first invalid record, emit one of these exact diagnostics, checking fields in this order:
1. `error: line N: expected 3 fields`
2. `error: line N: invalid name`
3. `error: line N: invalid kind`
4. `error: line N: invalid size`
5. `error: line N: duplicate name NAME`

Output each retained record as `name|kind|size\n` without padding, normalizing sizes to ordinary decimal. With `--total`, append `total|COUNT|SUM\n`, where COUNT and SUM include only retained records; SUM must support totals exceeding u64 (use u128). Empty results produce empty output, or `total|0|0\n` with `--total`. A missing final input newline is accepted. No external crates or network access.

Run `cargo test --offline`.
