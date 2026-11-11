import argparse, json, sys
from .clock import seconds
from .service import settle
def main():
    parser=argparse.ArgumentParser()
    parser.add_argument('--now',type=int,default=None)
    args=parser.parse_args()
    print(json.dumps(settle(sys.stdin,sys.stdout,seconds() if args.now is None else args.now)),file=sys.stderr)
if __name__=='__main__': main()
