from itertools import chain
def pages(*sources): return chain.from_iterable(sources)
