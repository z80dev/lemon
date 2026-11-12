from .model import Entry
from .projection import Projection
from .memory import Feed
def check():
    feed=Feed();feed.append(Entry('health','probe',0,1))
    return Projection(feed).balances(0)=={'health':1}
