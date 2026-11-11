"""Vendored provider: treat as immutable during the migration."""
import json
from copy import deepcopy
from dataclasses import dataclass


class MissingKey(LookupError):
    pass


@dataclass(frozen=True)
class Entry:
    key: str
    payload: bytes
    etag: str
    deleted: bool


@dataclass(frozen=True)
class Page:
    entries: tuple
    next_cursor: object


class Store:
    def __init__(self, records):
        self._records = deepcopy(list(records))
        self.active_sessions = 0
        self.scan_sizes = []

    def session(self):
        return Session(self)


class Session:
    def __init__(self, store):
        self.store = store
        self.open = False

    def __enter__(self):
        if self.open:
            raise RuntimeError("session already open")
        self.open = True
        self.store.active_sessions += 1
        return self

    def __exit__(self, *exc):
        self.open = False
        self.store.active_sessions -= 1

    def _require_open(self):
        if not self.open:
            raise RuntimeError("session is closed")

    def _entry(self, row):
        payload = row.get("raw_payload")
        if payload is None:
            payload = json.dumps(row.get("value"), ensure_ascii=False).encode("utf-8")
        return Entry(row["key"], payload, row.get("etag", "etag-1"), bool(row.get("deleted")))

    def scan(self, *, prefix="", cursor=None, page_size=2):
        self._require_open()
        if type(page_size) is not int or page_size <= 0:
            raise ValueError("page_size must be a positive integer")
        self.store.scan_sizes.append(page_size)
        rows = [row for row in self.store._records
                if row.get("checkpoint") or row["key"].startswith(prefix)]
        if cursor is None:
            start = 0
        elif isinstance(cursor, str) and cursor.startswith("shelf@"):
            start = int(cursor[6:], 16)
        else:
            raise ValueError("opaque cursor required")
        end = start + page_size
        entries = tuple(self._entry(row) for row in rows[start:end] if not row.get("checkpoint"))
        following = "shelf@%x" % end if end < len(rows) else None
        return Page(entries, following)

    def read(self, key):
        self._require_open()
        for row in self.store._records:
            if row.get("key") == key:
                if row.get("deleted"):
                    break
                return self._entry(row)
        raise MissingKey(key)
