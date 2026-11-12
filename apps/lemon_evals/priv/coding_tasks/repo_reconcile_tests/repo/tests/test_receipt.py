import unittest
from settler.receipt import receipt
from settler.health import check
from settler.formatting import money
class ReceiptTests(unittest.TestCase):
    def test_receipt(self): self.assertEqual(receipt({'a':5,'b':-2}),{'accounts':2,'net':3})
    def test_format(self): self.assertEqual(money(-12),'-0.12')
    def test_health(self): self.assertTrue(check())
