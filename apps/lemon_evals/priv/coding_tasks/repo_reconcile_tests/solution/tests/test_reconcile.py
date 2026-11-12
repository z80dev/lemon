import unittest
from settler.model import Entry as E
from settler.reconcile import reconcile
class ReconcileTests(unittest.TestCase):
    def test_empty(self): self.assertEqual(reconcile(iter(()),0),{})
    def test_latest_and_distinct_account(self):
        events=[E('z','same',4,9),E('z','same',1,2),E('a','same',2,8)]
        self.assertEqual(reconcile(events,0),{'a':8,'z':9})
        self.assertEqual(list(reconcile(events,0)),['a','z'])
    def test_last_tie(self):
        self.assertEqual(reconcile([E('a','x',2,4),E('a','x',2,7)],0),{'a':7})
    def test_expiry_and_void_do_not_resurrect(self):
        entries=[E('a','x',0,9),E('a','x',1,2,10),E('a','y',0,8),E('a','y',2,5,void=True),E('a','z',0,3,11)]
        self.assertEqual(reconcile(entries,10),{'a':3})
        self.assertEqual(reconcile([E('a','x',0,9,0)],0),{})
    def test_negative_zero_sorted(self):
        entries=[E('z','x',0,3),E('b','x',0,-8),E('a','x',0,3),E('a','y',0,-3),E('c','x',0,0)]
        self.assertEqual(reconcile(entries,0),{'b':-8,'z':3})
        self.assertEqual(list(reconcile(entries,0)),['b','z'])
    def test_generator_and_no_mutation(self):
        entries=[E('a','x',0,8),E('a','y',0,-3)]
        original=list(entries)
        self.assertEqual(reconcile((e for e in entries),0),{'a':5})
        self.assertEqual(entries,original)
    def test_invalid_now(self):
        with self.assertRaises(ValueError): reconcile([], -1)
    def test_invalid_entries_even_if_losing(self):
        for bad in [E('','x',0,1),E('a','',0,1),E('a','x',-1,1,0,True)]:
            with self.subTest(bad=bad):
                with self.assertRaises(ValueError): reconcile([E('a','x',3,5),bad],10)
