# Context references and document extraction

Lemon has one client-independent context service for inspecting and selecting
repository, URL, document, diff, and prior-session material before it is handed
to another workflow. The source and packaged launchers expose that service as
`lemon context`; both commands return the same versioned, redacted contract.

## Preview before resolving

Use preview to run the real selection and safety checks without returning the
selected text:

```bash
./bin/lemon context preview \
  '@file:docs/brief.docx' \
  '@folder:notes' \
  '@git-diff' \
  --root "$PWD" \
  --max-bytes 120000 \
  --json
```

Resolve uses the same budget and returns the selected text:

```bash
./bin/lemon context resolve '@file:analysis.ipynb' --root "$PWD"
```

Installed releases use `lemon context ...` with the same arguments. Quote
references in a shell so characters such as `?`, `*`, and `~` are not expanded
before Lemon receives them.

## Reference forms

| Form | Selection |
| --- | --- |
| `@file:<path>` | One regular file below `--root`. PDF, Office, notebook, and text formats are sniffed from bytes. |
| `@folder:<path>` | Deterministic recursive selection of regular files below `--root`. |
| `@git-diff` | Unstaged working-tree diff for `--root`. |
| `@git-diff:staged` | Staged diff. |
| `@git-diff:<revision>` | Diff from a validated revision. Git is invoked directly, never through a shell. |
| `@url:<http(s)-url>` | Public URL fetched through DNS/IP SSRF checks and redirect revalidation. |
| `@session:<session-key>` | Existing canonical, always-redacted Markdown session export. |

Local paths are expanded beneath the selected root. Absolute paths outside the
root, `..` traversal, symlinks at any selected component, special files, and
symlinked folder entries are rejected or recorded as omissions. Folder walks
never follow symlinks.

## Budget and output contract

Every response is version `1` and contains:

- the exact effective input, output, item, depth, page, archive, ratio, and
  operation-time limits;
- selected source metadata and, for resolve, selected redacted text;
- selected byte/item/source counts and a redaction count;
- structured omissions for unsupported, unsafe, over-budget, truncated, or
  unavailable material.

The useful CLI bounds are `--max-bytes`, `--max-input-bytes`, `--max-items`,
`--max-pages`, `--max-depth`, and `--timeout-ms`. The operation timeout is
hard-capped at 60 seconds. Limits are per invocation by design: a shared config
file cannot silently raise a caller's review budget.

Sensitive-looking assignments, bearer credentials, and private-key blocks are
redacted from selected text. URL output strips credentials, query strings, and
fragments from returned metadata; session keys are represented by a short
SHA-256 label. The selected text remains untrusted source material and should
not be treated as instructions.

## Document formats and safety

Lemon recognizes content rather than trusting extensions:

- PDF files start with the PDF signature. Literal text operators are selected;
  page count is bounded before selection.
- DOCX, XLSX, and PPTX are identified from ZIP members. Only the minimum text
  members are inflated.
- ipynb files must be JSON notebooks with a supported notebook structure. Cell
  source is selected; rich outputs are omitted.
- valid UTF-8 otherwise falls back to plain text.

Office containers are rejected before extraction when they exceed member,
expanded-byte, or compression-ratio limits, or contain absolute/traversal
member names. Macros, embedded objects, external relationships, notebook
outputs, and non-text payloads are never executed or selected.

The built-in PDF reader is deliberately conservative. Scanned, encrypted, and
many font-encoded or compressed-content PDFs return `pdf_text_unavailable`
instead of invoking an external program or guessing. Convert such a document
to trusted text with an operator-reviewed tool, then reference that text.

URL requests accept only HTTP(S), reject URL credentials, `.local`, loopback,
private, link-local, multicast, and metadata targets, connect to the validated
IP while retaining the original TLS SNI/Host identity, revalidate every
redirect, and cap request body and wall-clock time.
