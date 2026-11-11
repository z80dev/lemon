import json,sys
from .api import handle
def main():
    for line in sys.stdin:
        if line.strip(): print(json.dumps(handle(json.loads(line)),sort_keys=True))
if __name__=='__main__': main()
