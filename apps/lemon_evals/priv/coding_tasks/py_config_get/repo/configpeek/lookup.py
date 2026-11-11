"""Resolve object paths for both CLI and application callers."""


def resolve(document, path):
    value = document
    for segment in path.split("."):
        if not isinstance(value, dict):
            raise KeyError(path)
        value = value.get(segment)
        if not value:
            raise KeyError(path)
    return value
