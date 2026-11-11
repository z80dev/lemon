class PlanCache:
    def __init__(self): self._plans={}
    def get(self, country): return self._plans.get(country)
    def put(self, country, plan): self._plans[country]=plan
    def clear(self): self._plans.clear()
