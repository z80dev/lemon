from .address import lines
def render(address, reference): return '\n'.join([reference,*lines(address)])
