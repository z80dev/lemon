from .cache import PlanCache
from .eligibility import accepts
from .ranking import ordered
class Planner:
    def __init__(self, registry):
        self.registry=registry
        self.cache=PlanCache()
    def candidates(self, request):
        cached=self.cache.get(request.country)
        if cached is None:
            cached=ordered(rule for rule in self.registry.rules() if accepts(rule,request))
            self.cache.put(request.country,cached)
        return cached
