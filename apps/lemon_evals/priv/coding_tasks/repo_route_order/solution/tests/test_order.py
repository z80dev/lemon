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
