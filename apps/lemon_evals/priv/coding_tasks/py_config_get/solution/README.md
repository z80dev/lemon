# Configpeek

`python3 -m configpeek FILE KEY` reads UTF-8 JSON and selects dictionary keys
separated by dots. Keys are literal and case-sensitive, including numeric or
whitespace keys. There is no array indexing or escaping dots. Empty paths and
empty segments are usage errors; an intermediate non-object means missing.

A present value, including null and every falsy JSON value, prints compact JSON
with recursively sorted keys, unescaped Unicode, and one trailing newline.
Success exits 0 with empty stderr. Missing exits 3 with empty stdout and
`configpeek: key not found: KEY` plus newline on stderr. File, UTF-8, JSON syntax,
and NaN/Infinity failures exit 2 with empty stdout and
`configpeek: cannot read JSON: FILE` plus newline on stderr. Invalid invocation
is checked first and uses argparse's exit-2 error; `--help` exits 0.

Reusable modules: `lookup.resolve(document, path)` returns the value or raises
`KeyError(path)`; malformed paths raise `ValueError("invalid key path")`.
`storage.load_document(filename)` returns parsed JSON or raises `DocumentError`,
a ValueError with the original `filename` attribute and message
`cannot read JSON: FILE`. `cli.main(argv=None)` returns command exit status;
argparse may raise SystemExit for help or usage errors.

No installation needed. Run `python3 -m unittest discover -s tests -v`.
