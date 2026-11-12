class Feed:
    def __init__(self): self._items=[]
    def append(self, entry): self._items.append(entry)
    def snapshot(self): return tuple(self._items)
