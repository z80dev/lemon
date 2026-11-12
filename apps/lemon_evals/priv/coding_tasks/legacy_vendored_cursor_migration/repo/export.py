from vendor.shelf_v1 import scan


def export_records(store, prefix="", page_size=2):
    offset = 0
    result = []
    while True:
        page = scan(store, prefix, offset, page_size)
        result.extend(page["items"])
        if page["next"] is None:
            return sorted(result, key=lambda row: row["key"])
        offset = page["next"]
