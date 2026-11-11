"""Collection helpers."""


def paginate(items, page, page_size):
    if page <= 0 or page_size <= 0:
        raise ValueError("page and page_size must be positive")
    start = (page - 1) * page_size
    return items[start:start + page_size]
