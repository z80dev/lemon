from .cache import PlanCache
from .eligibility import accepts
from .ranking import ordered
class Planner:
    def __init__(self, registry):
        self.registry=registry
        self.cache=PlanCache()
    def candidates(self, request):
        generation=self.registry.generation
        cached=self.cache.get(generation,request.country)
        if cached is None:
            cached=tuple(ordered(rule for rule in self.registry.rules() if rule.country==request.country))
            self.cache.put(generation,request.country,cached)
        return [rule for rule in cached if accepts(rule,request)]
