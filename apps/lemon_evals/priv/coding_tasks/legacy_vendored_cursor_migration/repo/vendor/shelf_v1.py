def scan(store, prefix="", offset=0, limit=2):
    rows = [row for row in store._records if "key" in row
            and row["key"].startswith(prefix) and not row.get("deleted")]
    page = rows[offset:offset + limit]
    following = offset + limit if offset + limit < len(rows) else None
    return {"items": [{"key": row["key"], "value": row["value"]} for row in page],
            "next": following}


def get(store, key):
    for row in store._records:
        if row.get("key") == key and not row.get("deleted"):
            return row["value"]
    return None
