from .planner import Planner
from .validation import request
from .pricing import charge
from .response import quote
class QuoteService:
    def __init__(self, registry): self.planner=Planner(registry)
    def quote(self, country, tier, weight, hazmat=False):
        item=request(country,tier,weight,hazmat)
        candidates=self.planner.candidates(item)
        if not candidates: raise LookupError('NO_ROUTE')
        chosen=candidates[0]
        return quote(chosen,item,charge(chosen,item.weight))
