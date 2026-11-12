import unittest
from harbor.app import handle
from harbor.models import State
from harbor.examples import HEADERS, BODY
class FlowTests(unittest.TestCase):
    def test_create_then_replay(self):
        state=State()
        self.assertEqual(handle(state,'POST','/v1/reservations',HEADERS,BODY)['status'],201)
        self.assertEqual(handle(state,'POST','/v1/reservations',HEADERS,BODY)['status'],200)
        self.assertEqual(len(state.events),1)
    def test_route_precedes_auth(self):
        self.assertEqual(handle(State(),'GET','/missing',{},None)['code'],'NOT_FOUND')
