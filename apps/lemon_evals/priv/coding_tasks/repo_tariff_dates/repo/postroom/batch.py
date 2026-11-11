from .api import handle
def run(orders): return [handle(order) for order in orders]
