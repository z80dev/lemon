import argparse
import json
import sys
from .lookup import resolve, validate_path
from .storage import DocumentError, load_document


def main(argv=None):
    parser = argparse.ArgumentParser(prog="configpeek", description="Read a dotted key from a JSON file")
    parser.add_argument("file")
    parser.add_argument("key")
    args = parser.parse_args(argv)
    try:
        validate_path(args.key)
    except ValueError:
        parser.error("invalid key path")
    try:
        document = load_document(args.file)
    except DocumentError as error:
        print(f"configpeek: {error}", file=sys.stderr)
        return 2
    try:
        value = resolve(document, args.key)
    except KeyError:
        print(f"configpeek: key not found: {args.key}", file=sys.stderr)
        return 3
    print(json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":")))
    return 0
