from copy import deepcopy
from importlib import import_module
import unittest
from analytics import api
from analytics.ledger import Ledger


def arena_hidden_event(identity='a', tenant='t', revision=1, day='2026-01-01', value=5, deleted=False):
    return dict(id=identity, tenant=tenant, revision=revision, day=day, value=value, deleted=deleted)


class ArenaHiddenIncrementalRollups(unittest.TestCase):
    def test_every_source(self):
        self.assertEqual(sorted(api.SOURCES), sorted(['checkout','refund','shipment','return','signup','login','download','upload','render','query','backup','restore','scan','index','export','import']))
        for source in api.SOURCES:
            with self.subTest(source=source):
                def wire(event): return {source+'_'+k:v for k,v in event.items()}
                ledger = Ledger(); row = wire(arena_hidden_event())
                before = deepcopy(row)
                self.assertEqual(api.preview(source,ledger,[row]), [{'tenant':'t','day':'2026-01-01','value':5,'count':1}])
                self.assertEqual(ledger.totals(), [])
                api.ingest(source,ledger,[row]); api.ingest(source,ledger,[row])
                self.assertEqual(row,before)
                self.assertEqual(ledger.totals()[0]['count'],1)
                correction = wire(arena_hidden_event(revision=2,day='2026-01-02',value=-3))
                api.ingest(source,ledger,[correction])
                self.assertEqual(ledger.totals(),[{'tenant':'t','day':'2026-01-02','value':-3,'count':1}])
                snapshot = ledger.checkpoint()
                for method in [api.ingest,api.preview]:
                    with self.assertRaises(ValueError): method(source,ledger,[wire(arena_hidden_event('new')),{}])
                    self.assertEqual(ledger.checkpoint(),snapshot)
                adapter = import_module(f'sources.{source}.adapter').Adapter
                legacy = wire(arena_hidden_event());del legacy[source+'_revision'];del legacy[source+'_deleted']
                self.assertEqual(adapter.decode(legacy),arena_hidden_event())
                for bad in [None, {}, wire(arena_hidden_event(revision=True)), wire(arena_hidden_event(day='2026-02-30'))]:
                    with self.assertRaises(ValueError): adapter.decode(bad)

    def test_corrections_atomic_conflicts_and_recovery(self):
        ledger=Ledger(); events=[arena_hidden_event(),arena_hidden_event('b',value=-5),arena_hidden_event(tenant='u')]
        ledger.apply(events);events[0]['value']=999
        self.assertEqual(ledger.totals(),[{'tenant':'t','day':'2026-01-01','value':0,'count':2},{'tenant':'u','day':'2026-01-01','value':5,'count':1}])
        before=ledger.checkpoint()
        with self.assertRaises(ValueError): ledger.apply([arena_hidden_event('new'),arena_hidden_event(value=77)])
        self.assertEqual(ledger.checkpoint(),before)
        ledger.apply([arena_hidden_event(revision=3,value=0,deleted=True),arena_hidden_event(revision=2,value=100)])
        self.assertEqual(ledger.totals()[0]['value'],-5)
        restored=Ledger.restore(ledger.checkpoint()); restored.apply([arena_hidden_event()])
        self.assertEqual(restored.checkpoint(),ledger.checkpoint())
        restored.apply([arena_hidden_event('b',revision=2,value=0,deleted=True)])
        self.assertEqual(restored.totals(),[{'tenant':'u','day':'2026-01-01','value':5,'count':1}])
        checkpoint=ledger.checkpoint();clone=Ledger.restore(checkpoint);checkpoint['events'][0]['value']=1000
        self.assertEqual(clone.checkpoint(),ledger.checkpoint())
        totals=clone.totals();totals[0]['value']=1000
        self.assertEqual(clone.totals(),ledger.totals())
        unordered=ledger.checkpoint();unordered['events'].reverse()
        self.assertEqual(Ledger.restore(unordered).checkpoint(),ledger.checkpoint())
        bad=ledger.checkpoint();bad['events'].append(deepcopy(bad['events'][0]))
        with self.assertRaises(ValueError): Ledger.restore(bad)
        for event in [arena_hidden_event(revision=0),arena_hidden_event(value=True),arena_hidden_event(day='20260101'),arena_hidden_event(deleted=True),{'id':'x'}]:
            with self.assertRaises(ValueError): ledger.apply([arena_hidden_event('new'),event])
        self.assertEqual(ledger.checkpoint(),clone.checkpoint())
        with self.assertRaises(ValueError): api.ingest('unknown',ledger,[])
        with self.assertRaises(ValueError): api.preview('unknown',ledger,[])
        # Corrections through a different source replace the same canonical identity.
        api.ingest(api.SOURCES[1],ledger,[{api.SOURCES[1]+'_'+k:v for k,v in arena_hidden_event(revision=4,value=8).items()}])
        self.assertEqual(ledger.totals()[0]['value'],3)

if __name__=='__main__': unittest.main()
