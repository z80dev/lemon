import unittest
from analytics.ledger import Ledger


def event(revision=1, value=5, deleted=False):
    return {'id': 'a', 'tenant': 't', 'revision': revision, 'day': '2026-01-01',
            'value': value, 'deleted': deleted}


class RollupRecoveryTest(unittest.TestCase):
    def test_tombstone_survives_restart(self):
        ledger = Ledger()
        ledger.apply([event(), event(2, 0, True)])
        restored = Ledger.restore(ledger.checkpoint())
        restored.apply([event()])
        self.assertEqual(restored.totals(), [])
        restored.apply([event(3, -7)])
        self.assertEqual(restored.totals(), [{'tenant': 't', 'day': '2026-01-01', 'value': -7, 'count': 1}])

    def test_conflict_rolls_back_prior_batch_events(self):
        ledger = Ledger()
        ledger.apply([event()])
        before = ledger.checkpoint()
        with self.assertRaises(ValueError):
            ledger.apply([{**event(), 'id': 'new'}, event(1, 7)])
        self.assertEqual(ledger.checkpoint(), before)
