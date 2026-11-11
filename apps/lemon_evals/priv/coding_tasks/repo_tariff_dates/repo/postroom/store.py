import json
class OrderStore:
    def __init__(self,path): self.path=path
    def save(self,orders): self.path.write_text(json.dumps(orders,sort_keys=True))
    def load(self): return json.loads(self.path.read_text()) if self.path.exists() else []
