---
name: pinata
description: Pin files and JSON to IPFS via Pinata (JWT auth + helper scripts).
homepage: https://docs.pinata.cloud/
metadata:
  {
    "lemon":
      {
        "emoji": "📌",
        "requires":
          {
            "config": ["PINATA_JWT"],
            "bins": ["curl"],
          },
      },
  }
---

# Pinata

Use Pinata to pin content to IPFS.

This skill ships with small scripts (in `scripts/`) that wrap the Pinata API with
reasonable defaults. Prefer `PINATA_JWT` auth.

## Setup

Auth (recommended):

- Set `PINATA_JWT` to a Pinata JWT (Bearer token).

Optional (legacy-only, not supported by all endpoints):

- Set `PINATA_API_KEY` and `PINATA_API_SECRET` (some older endpoints accept these).

Optional endpoint overrides:

- `PINATA_API_URL` (default: `https://api.pinata.cloud`)
- `PINATA_UPLOAD_URL` (default: `https://uploads.pinata.cloud`)

## Quickstart

Run these from the Pinata skill directory (seeded to `~/.lemon/agent/skill/pinata`
by default):

Test auth:

```bash
./scripts/auth-test.sh
```

Upload a file (Pinata v3 uploads API):

```bash
./scripts/upload-file.sh ./path/to/file.png --network private --name file.png
```

Pin a JSON document (wraps your JSON as `pinataContent`):

```bash
./scripts/pin-json.sh ./metadata.json --name "metadata.json"
```

Pin an existing CID (by hash):

```bash
./scripts/pin-by-hash.sh bafy... --name "my-cid"
```

Unpin:

```bash
./scripts/unpin.sh bafy...
```

## Notes

- These scripts print raw JSON responses (so you can pipe into `jq` if you want).
- For very large uploads, resumable uploads, or folder uploads, consider Pinata’s
  official tooling and docs: https://docs.pinata.cloud/
