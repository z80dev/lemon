import unittest
from routing import parse, matches
from routing.rules import select

class RoutingTests(unittest.TestCase):
    def test_existing_comparison(self):
        self.assertEqual(parse('carrier == "blue"'),('eq','carrier','blue'))
        self.assertTrue(matches(parse('carrier != "red"'),{'carrier':'blue'}))
        self.assertFalse(matches(parse('carrier != "red"'),{}))
    def test_boolean_routes(self):
        source='region == "west" || priority == "high" && ! carrier == "slow"'
        self.assertEqual(select({'express':source},{'region':'east','priority':'high','carrier':'fast'}),['express'])
        self.assertEqual(parse('a == "1" || b == "2" && c == "3"'),('or',('eq','a','1'),('and',('eq','b','2'),('eq','c','3'))))
