import json, sys
from .app import handle
from .models import State
from .examples import HEADERS, BODY
from .reports import summary
def main():
    state=State()
    print(json.dumps(handle(state,'POST','/v1/reservations',HEADERS,BODY),sort_keys=True))
    print(json.dumps(summary(state),sort_keys=True))
if __name__ == '__main__': main()
