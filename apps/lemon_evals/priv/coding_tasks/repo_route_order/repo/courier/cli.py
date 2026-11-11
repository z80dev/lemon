import json, sys
from .bootstrap import registry
from .service import QuoteService
from .api import handle
from .warmup import warm
def main():
    service=QuoteService(registry())
    warm(service,['US','DE','CA'])
    for line in sys.stdin:
        if line.strip(): print(json.dumps(handle(service,json.loads(line)),sort_keys=True))
if __name__=='__main__': main()
