import unittest
from courier.bootstrap import registry
from courier.service import QuoteService
from courier.model import Rule
from courier.warmup import warm
from courier.registry import Registry
class OrderTests(unittest.TestCase):
    def test_warmup_and_request_dimensions(self):
        service=QuoteService(registry()); warm(service,['US'])
        self.assertEqual(service.quote(' us ','priority',2)['route'],'air')
        self.assertEqual(service.quote('US','standard',2,True)['route'],'hazmat')
        self.assertEqual(service.quote('US','priority',20)['route'],'ground')
        with self.assertRaises(LookupError): service.quote('US','standard',40)
    def test_generation_and_tie(self):
        store=Registry(); service=QuoteService(store)
        with self.assertRaises(LookupError): service.quote('CA','standard',1)
        store.register(Rule('z','CA',('standard',),10,True,10,1,1))
        store.register(Rule('a','CA',('standard',),10,True,20,1,1))
        self.assertEqual(service.quote('CA','standard',1)['route'],'a')
        store.remove('a')
        self.assertEqual(service.quote('CA','standard',1)['route'],'z')
        store.register(Rule('z','CA',('standard',),10,True,90,1,1))
        self.assertEqual(service.quote('CA','standard',1)['cents'],91)

class MatrixTests(unittest.TestCase):
    def test_every_order(self):
        from itertools import permutations
        requests=[('US','standard',2,False),('US','priority',2,False),('US','priority',20,False),('US','priority',2,True),('US','standard',40,False),('DE','standard',2,False)]
        def outcome(service, args):
            try: return service.quote(*args)
            except LookupError as exc: return str(exc)
        expected=[outcome(QuoteService(registry()),args) for args in requests]
        for order in permutations(range(len(requests))):
            service=QuoteService(registry())
            for i in order: self.assertEqual(outcome(service,requests[i]),expected[i])
    def test_plugin_order(self):
        from courier import ground,air,dangerous,europe,partners
        from itertools import permutations
        for order in permutations([ground,air,dangerous,europe,partners]):
            self.assertEqual(QuoteService(registry(order)).quote('CA','standard',1)['route'],'alpha')
    def test_removed_last_and_readded(self):
        store=Registry(); service=QuoteService(store)
        store.register(Rule('x','NZ',('priority',),3,False,10,1,1))
        self.assertEqual(service.quote('NZ','priority',2)['cents'],12)
        store.remove('x')
        with self.assertRaisesRegex(LookupError,'NO_ROUTE'): service.quote('NZ','priority',2)
        store.register(Rule('x','NZ',('priority',),1,False,20,1,1))
        with self.assertRaisesRegex(LookupError,'NO_ROUTE'): service.quote('NZ','priority',2)
        self.assertEqual(service.quote('NZ','priority',1)['cents'],21)
    def test_validation(self):
        service=QuoteService(registry())
        for field,bad,code in [('country','','COUNTRY'),('tier','rush','TIER'),('weight',True,'WEIGHT'),('weight',-1,'WEIGHT'),('hazmat',1,'HAZMAT')]:
            kwargs=dict(country='US',tier='standard',weight=1,hazmat=False);kwargs[field]=bad
            with self.assertRaisesRegex(ValueError,code): service.quote(**kwargs)
    def test_exact_response(self):
        self.assertEqual(QuoteService(registry()).quote(' us ','priority',2,True),{'route':'hazmat','country':'US','tier':'priority','weight':2,'hazmat':True,'cents':1100})
