class PlanCache:
    def __init__(self): self._plans={}
    def get(self, generation, country): return self._plans.get((generation,country))
    def put(self, generation, country, plan):
        # Keep only the active registry generation to bound stale plans.
        self._plans={key:value for key,value in self._plans.items() if key[0]==generation}
        self._plans[(generation,country)]=tuple(plan)
    def clear(self): self._plans.clear()
