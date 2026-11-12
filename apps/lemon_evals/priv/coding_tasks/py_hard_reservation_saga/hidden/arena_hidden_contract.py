from copy import deepcopy
from importlib import import_module
from pathlib import Path
import json
import unittest
from inventory.api import PRODUCTS, make_service
from inventory.engine import Engine

class ArenaHiddenReservationSaga(unittest.TestCase):
    def test_products(self):
        products = ['air','rail','hotel','car','ferry','tour','museum','theater','parking','camp','cruise','bike','shuttle','lounge','locker','workspace']
        self.assertEqual(sorted(PRODUCTS), sorted(products))
        for index, product in enumerate(products):
            with self.subTest(product=product):
                policy = json.loads(Path(f'products/{product}/policy.json').read_text())
                for field, value in {'sku_field':product+'_code','quantity_field':product+'_count','prefix':product+':','limit':8+index}.items():
                    self.assertEqual(policy[field], value)
                sku = product + ':seat'
                engine = Engine({sku: 100})
                service = make_service(product, engine)
                raw = {'key': 'new', 'items': [{'sku': sku, 'units': 2}, {'sku': sku, 'units': 1}]}
                original = deepcopy(raw)
                receipt = service.book(raw)
                self.assertEqual(receipt, {'key': 'new', 'status': 'reserved', 'lines': [[sku, 3]]})
                self.assertEqual(raw, original)
                receipt['lines'][0][1] = 99
                self.assertEqual(service.book(raw)['lines'], [[sku, 3]])
                self.assertEqual(engine.stock[sku], 97)
                legacy = {'request_id': 'old', policy['sku_field']: sku, policy['quantity_field']: 2}
                service.book(legacy); service.book(legacy)
                self.assertEqual(engine.stock[sku], 95)
                service.cancel('new'); service.cancel('new')
                self.assertEqual(engine.stock[sku], 98)
                self.assertEqual(service.book(raw)['status'], 'cancelled')
                restored = Engine.restore(service.snapshot())
                self.assertEqual(restored.snapshot(), service.snapshot())
                self.assertEqual(make_service(product, restored).book(raw)['status'], 'cancelled')
                repository = import_module(f'products.{product}.repository').Repository(restored)
                repository.reserve('direct', [(sku, 1)]); repository.cancel('direct')
                self.assertEqual(repository.snapshot(), restored.snapshot())
                for bad in [None, {}, {'key':'x','items':[]}, {'key':'x','items':[{}]},
                            {'key':'x','items':[{'sku':'wrong:seat','units':1}]},
                            {'key':'x','items':[{'sku':sku,'units':True}]},
                            {'key':'x','items':[{'sku':sku,'units':policy['limit']+1}]}]:
                    before = engine.snapshot()
                    with self.assertRaises(ValueError): service.book(bad)
                    self.assertEqual(engine.snapshot(), before)

    def test_atomic_engine_and_aliases(self):
        engine = Engine({'a': 4, 'b': 2})
        for lines in [[('a',2),('b',3)], [('a',1),('missing',1)], [('a',True)], [], None, [('a',1),('b',0)]]:
            before = engine.snapshot()
            with self.assertRaises(ValueError): engine.reserve('bad', lines)
            self.assertEqual(engine.snapshot(), before)
        engine.reserve('z', [('b',1),('a',1),('a',1)])
        self.assertEqual(engine.reserve('z', [('a',2),('b',1)])['lines'], [['a',2],['b',1]])
        with self.assertRaises(ValueError): engine.reserve('z', [('a',1)])
        with self.assertRaises(ValueError): engine.cancel('unknown')
        engine.reserve('a', [('a',1)])
        snapshot = engine.snapshot(); restored = Engine.restore(snapshot)
        snapshot['stock']['a'] = 999; snapshot['receipts'][0]['lines'][0][1] = 99
        self.assertEqual([r['key'] for r in restored.snapshot()['receipts']], ['a','z'])
        restored.cancel('z'); restored.cancel('z')
        self.assertEqual(restored.stock, {'a':3,'b':2})
        self.assertNotEqual(restored.snapshot(), engine.snapshot())
        for bad in [None, {}, {'version':1,'stock':{},'receipts':[]}, {'version':2,'stock':{'a':True},'receipts':[]}]:
            with self.assertRaises(ValueError): Engine.restore(bad)
        base = engine.snapshot()
        mutations = []
        for key,value in [('status','pending'),('lines',[['a',1],['a',1]]),('lines',[['unknown',1]]),('lines',[['b',1],['a',1]])]:
            bad = deepcopy(base); bad['receipts'][0][key] = value; mutations.append(bad)
        bad = deepcopy(base);bad['receipts'].append(deepcopy(bad['receipts'][0]));mutations.append(bad)
        for bad in mutations:
            with self.assertRaises(ValueError): Engine.restore(bad)

if __name__ == '__main__': unittest.main()
