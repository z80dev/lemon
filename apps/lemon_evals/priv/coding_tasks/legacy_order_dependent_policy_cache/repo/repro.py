import argparse
import random
import unittest


def flatten(suite):
    for item in suite:
        if isinstance(item, unittest.TestSuite):
            yield from flatten(item)
        else:
            yield item


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--seed", type=int, default=0)
    args = parser.parse_args()
    cases = list(flatten(unittest.defaultTestLoader.discover(".", pattern="test*.py")))
    random.Random(args.seed).shuffle(cases)
    result = unittest.TextTestRunner(verbosity=2).run(unittest.TestSuite(cases))
    return 0 if result.wasSuccessful() else 1


if __name__ == "__main__":
    raise SystemExit(main())
