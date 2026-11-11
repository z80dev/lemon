class Registry:
    def __init__(self):
        self._rules={}
        self.generation=0
    def register(self, rule):
        self._rules[rule.code]=rule
        self.generation+=1
    def remove(self, code):
        if code in self._rules:
            del self._rules[code]
            self.generation+=1
    def rules(self): return tuple(self._rules.values())
