import argparse
import json
from .repository import Repository
from .service import Service


def main(argv=None):
    parser = argparse.ArgumentParser()
    parser.add_argument("--db", required=True)
    commands = parser.add_subparsers(dest="command", required=True)
    add = commands.add_parser("add")
    add.add_argument("sku")
    add.add_argument("quantity", type=int)
    commands.add_parser("list")
    args = parser.parse_args(argv)
    repository = Repository(args.db)
    service = Service(repository)
    try:
        if args.command == "add":
            stock = service.add_stock(args.sku, args.quantity)
            result = {"sku": stock.sku, "quantity": stock.quantity}
        else:
            result = [{"sku": row.sku, "quantity": row.quantity}
                      for row in service.inventory()]
        print(json.dumps(result, sort_keys=True))
        return 0
    finally:
        repository.close()


if __name__ == "__main__":
    raise SystemExit(main())
