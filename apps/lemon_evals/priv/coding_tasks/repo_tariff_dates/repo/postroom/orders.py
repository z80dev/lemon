from .weights import packed
from .lanes import for_depot
def invoice(order):
    return {'lane':for_depot(order['depot']),'grams':packed(order['items']),
            'shipping_date':order['shipping_date'],'billed_on':order['billed_on'],
            'handling_cents':order.get('handling_cents',0)}
