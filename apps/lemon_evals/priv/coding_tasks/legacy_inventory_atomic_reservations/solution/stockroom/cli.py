import argparse
import json
import sys
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
    reserve = commands.add_parser("reserve")
    reserve.add_argument("order_id")
    reserve.add_argument("lines", nargs="+")
    args = parser.parse_args(argv)
    repository = Repository(args.db)
    service = Service(repository)
    try:
        if args.command == "add":
            stock = service.add_stock(args.sku, args.quantity)
            result = {"sku": stock.sku, "quantity": stock.quantity}
        elif args.command == "reserve":
            lines = []
            for line in args.lines:
                try:
                    sku, quantity = line.rsplit(":", 1)
                    quantity = int(quantity)
                except ValueError:
                    raise ValueError("reservation lines must use SKU:QUANTITY") from None
                lines.append({"sku": sku, "quantity": quantity})
            result = service.reserve(args.order_id, lines)
        else:
            result = [{"sku": row.sku, "quantity": row.quantity}
                      for row in service.inventory()]
        print(json.dumps(result, sort_keys=True))
        return 0
    except (ValueError, KeyError) as error:
        print(str(error), file=sys.stderr)
        return 2
    finally:
        repository.close()


if __name__ == "__main__":
    raise SystemExit(main())
