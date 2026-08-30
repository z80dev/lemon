# Learn from files, folders, and URLs

Lemon can turn bounded context sources into durable memory and a reviewable
skill draft without executing the source or creating another learning
database. The workflow is always review first: the first command does not write
anything, and the second command must repeat the exact source selection with
the confirmation digest from that review.

## Review without writing

```bash
lemon learn \
  '@file:docs/operations.md' \
  '@folder:runbooks' \
  '@url:https://example.com/public-guide' \
  --root "$PWD" \
  --agent-id operator \
  --json
```

A source checkout uses `./bin/lemon learn ...` with the same arguments. Review
returns:

- selected source/item/byte and omission counts;
- SHA-256 provenance and content digests, never source paths or URLs;
- the deterministic memory ID, scope, action, summary size, and digest;
- the synthesis-draft key, action, bundle size/digest, audit verdict, and audit
  rule identifiers;
- destination conflicts and `canConfirm`;
- one exact `confirmationDigest`.

It never returns source text, extracted document text, a generated prompt,
skill body, local path, URL, secret name, or secret value. Content selected by
`LemonCore.Context` is redacted again at the durable-memory boundary.

## Confirm the exact fresh plan

Repeat every reference and option from review:

```bash
lemon learn confirm \
  '@file:docs/operations.md' \
  '@folder:runbooks' \
  '@url:https://example.com/public-guide' \
  --root "$PWD" \
  --agent-id operator \
  --confirm <64-character-review-digest> \
  --json
```

Confirmation re-resolves all sources under the same byte, item, page, depth,
archive, redirect, SSRF, and timeout limits. It also checks the current memory
row, draft destination, and deterministic skill audit. A changed source,
changed destination, collision, or blocked audit fails closed before a durable
write.

On success Lemon writes one deterministic `LemonMemory.Document` through the
existing SQLite memory store and one audited candidate through the existing
synthesis `DraftStore`. The skill is not installed or executed; it remains in
the ordinary draft/promotion flow for inspection and editing. Both records
carry the source content digest and hashed per-source provenance; the draft
also carries its exact source memory document ID and audited bundle digest.
They remain ordinary records: remove the memory by exact document ID through
`LemonMemory.Store.delete_document/1` and the candidate by exact key through
`LemonSkills.Synthesis.DraftStore.delete/2`.

Run review again after confirmation to get an idempotent `unchanged` plan. This
fresh digest can be confirmed without creating a duplicate memory row or skill
draft.

## Scope and safety

- Local paths remain confined to `--root`; traversal, symlinks, and special
  files are rejected or omitted.
- URLs use DNS/IP-pinned public HTTP(S) fetching and revalidate every redirect.
- PDF, Office, notebook, archive, folder, and text extraction use the same
  explicit limits documented in [Context references](context-references.md).
- `--project` writes the candidate draft under the project `.lemon` scope;
  otherwise it uses the existing global draft scope.
- `--agent-id` selects the durable memory owner. `--session-key` is available
  for an explicit canonical learning session.
- Learning uses only the deterministic skill audit. It never sends selected
  source content to the optional LLM audit reviewer.

The authenticated control plane exposes the same service as `learn.review`
(read scope) and `learn.confirm` (admin scope).
