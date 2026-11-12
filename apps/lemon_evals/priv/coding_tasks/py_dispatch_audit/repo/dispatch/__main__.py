import argparse
import json
from .manifest import load
from .report import summarize

parser = argparse.ArgumentParser(description="Summarize carrier settlement")
parser.add_argument("manifest")
args = parser.parse_args()
shipments, rebates = load(args.manifest)
print(json.dumps(summarize(shipments, rebates), sort_keys=True, indent=2))
