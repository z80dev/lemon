import json


def export_records(store, prefix="", page_size=2):
    result = []
    with store.session() as session:
        cursor = None
        while True:
            page = session.scan(prefix=prefix, cursor=cursor, page_size=page_size)
            for entry in page.entries:
                if not entry.deleted:
                    result.append({"key": entry.key,
                                   "value": json.loads(entry.payload.decode("utf-8"))})
            cursor = page.next_cursor
            if cursor is None:
                break
    return sorted(result, key=lambda row: row["key"])
