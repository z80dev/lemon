import unittest
from inventory.engine import Engine
from inventory.api import make_service


class SagaLifecycleTest(unittest.TestCase):
    def test_cross_product_restart_and_cancellation(self):
        engine = Engine({'air:one': 3, 'hotel:one': 3})
        air = make_service('air', engine)
        hotel = make_service('hotel', engine)
        air.book({'key': 'trip-air', 'items': [{'sku': 'air:one', 'units': 2}]})
        hotel.book({'key': 'trip-hotel', 'items': [{'sku': 'hotel:one', 'units': 1}]})
        restarted = Engine.restore(engine.snapshot())
        restarted.cancel('trip-air')
        restarted.cancel('trip-air')
        self.assertEqual(restarted.stock, {'air:one': 3, 'hotel:one': 2})
        self.assertEqual(restarted.reserve('trip-air', [('air:one', 2)])['status'], 'cancelled')

    def test_failed_multi_sku_request_is_atomic(self):
        engine = Engine({'a': 4, 'b': 1})
        before = engine.snapshot()
        with self.assertRaises(ValueError):
            engine.reserve('trip', [('a', 2), ('b', 2)])
        self.assertEqual(engine.snapshot(), before)
        engine.reserve('trip', [('a', 2), ('a', 1)])
        self.assertEqual(engine.reserve('trip', [('a', 3)])['lines'], [['a', 3]])
