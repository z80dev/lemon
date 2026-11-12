class Repository:
    def __init__(self, engine):
        self.engine = engine

    def reserve(self, key, lines):
        return self.engine.reserve(key, lines)

    def cancel(self, key):
        return self.engine.cancel(key)

    def snapshot(self):
        return self.engine.snapshot()
