from .registry import Registry
from . import ground, air, dangerous, europe, partners
def registry(order=None):
    result=Registry()
    for plugin in order or (ground,air,dangerous,europe,partners):
        for rule in plugin.rules(): result.register(rule)
    return result
