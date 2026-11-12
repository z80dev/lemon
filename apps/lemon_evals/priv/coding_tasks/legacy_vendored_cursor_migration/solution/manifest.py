import json

from export import export_records


def build_manifest(store, prefix=""):
    rows = export_records(store, prefix)
    return {
        "count": len(rows),
        "keys": [row["key"] for row in rows],
        "total_bytes": sum(
            len(json.dumps(row["value"], ensure_ascii=False, sort_keys=True,
                           separators=(",", ":")).encode("utf-8"))
            for row in rows
        ),
    }
