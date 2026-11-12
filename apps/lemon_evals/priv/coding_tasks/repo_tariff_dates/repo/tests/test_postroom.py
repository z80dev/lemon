import unittest
from postroom.samples import order
from postroom.dispatch import dispatch
from postroom.weights import packed
from postroom.orders import invoice
class PostroomTests(unittest.TestCase):
    def test_weight(self): self.assertEqual(packed([{'grams':10,'quantity':3},{'grams':4}]),34)
    def test_old_rate(self): self.assertEqual(dispatch(order())['quote'],{'postage_cents':266,'handling_cents':20,'total_cents':286})
    def test_shipping_date_preserved(self): self.assertEqual(invoice(order())['shipping_date'],'2024-04-01')
