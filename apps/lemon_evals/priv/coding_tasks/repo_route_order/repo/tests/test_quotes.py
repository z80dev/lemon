import unittest
from courier.bootstrap import registry
from courier.service import QuoteService
from courier.api import handle
class QuoteTests(unittest.TestCase):
    def test_ground(self): self.assertEqual(QuoteService(registry()).quote('US','standard',2)['route'],'ground')
    def test_air(self): self.assertEqual(QuoteService(registry()).quote('US','priority',2)['route'],'air')
    def test_reject(self): self.assertEqual(handle(QuoteService(registry()),{'country':'US','tier':'priority','weight':0}),{'status':400,'error':'WEIGHT'})
