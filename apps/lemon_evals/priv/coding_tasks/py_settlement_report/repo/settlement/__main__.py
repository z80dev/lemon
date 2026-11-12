import argparse
import json
from .report import build_report

def main():
    parser = argparse.ArgumentParser(description='Export monthly merchant settlement totals')
    parser.add_argument('source')
    parser.add_argument('--month', required=True)
    parser.add_argument('--zone', default='UTC')
    args = parser.parse_args()
    with open(args.source, encoding='utf-8') as handle:
        document = json.load(handle)
    print(json.dumps(build_report(document, args.month, args.zone), sort_keys=True))

if __name__ == '__main__':
    main()
