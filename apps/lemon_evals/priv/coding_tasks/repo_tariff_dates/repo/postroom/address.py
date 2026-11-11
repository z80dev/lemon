def lines(address):
    return [address[k] for k in ('name','street','city','postal','country') if address.get(k)]
