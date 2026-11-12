from vendor.shelf_v1 import scan


def build_manifest(store, prefix=""):
    page = scan(store, prefix, 0, 100)
    rows = sorted(page["items"], key=lambda row: row["key"])
    return {"count": len(rows), "keys": [row["key"] for row in rows],
            "total_bytes": sum(len(str(row["value"])) for row in rows)}
