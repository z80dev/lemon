from .reconcile import reconcile
class Projection:
    def __init__(self, feed): self.feed=feed
    def balances(self, now): return reconcile(self.feed.snapshot(),now)
