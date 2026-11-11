"""Resolve dictionary-only dotted paths without conflating missing and null."""


def validate_path(path):
    if not path or any(not segment for segment in path.split(".")):
        raise ValueError("invalid key path")
    return path.split(".")


def resolve(document, path):
    value = document
    for segment in validate_path(path):
        if not isinstance(value, dict) or segment not in value:
            raise KeyError(path)
        value = value[segment]
    return value
