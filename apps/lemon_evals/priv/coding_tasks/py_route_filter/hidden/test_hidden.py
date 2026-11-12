import copy
import random
import unittest
from routing import parse, matches, ParseError
from routing.rules import select

def quoted(value):
    return '"'+value.replace('\\','\\\\').replace('"','\\"').replace('\n','\\n').replace('\t','\\t')+'"'

def render(ast):
    if ast[0] in ('eq','ne'):
        return ast[1]+(' == ' if ast[0]=='eq' else ' != ')+quoted(ast[2])
    if ast[0]=='not': return '! ('+render(ast[1])+')'
    return '('+render(ast[1])+(' && ' if ast[0]=='and' else ' || ')+render(ast[2])+')'

class Contract(unittest.TestCase):
    def test_precedence_and_association(self):
        a=('eq','a','1'); b=('ne','b','2'); c=('eq','c','3')
        self.assertEqual(parse('a=="1"||b!="2"&&!!c=="3"'),('or',a,('and',b,('not',('not',c)))))
        self.assertEqual(parse('a=="1"||b!="2"||c=="3"'),('or',('or',a,b),c))
        self.assertEqual(parse('a=="1"&&b!="2"&&c=="3"'),('and',('and',a,b),c))
        self.assertEqual(parse('! (a=="1" || b!="2")'),('not',('or',a,b)))
    def test_strings_and_evaluation(self):
        value='héllo " || \\ \n\t !'
        self.assertEqual(parse(' shipment.route-id \t== '+quoted(value)),('eq','shipment.route-id',value))
        record={'shipment.route-id':value,'x':''}; before=copy.deepcopy(record)
        self.assertTrue(matches(parse('shipment.route-id == '+quoted(value)),record))
        self.assertTrue(matches(parse('!(missing != "x")'),record))
        self.assertFalse(matches(parse('missing == "" || missing != ""'),record))
        self.assertFalse(matches(parse('x == "X"'),record))
        self.assertTrue(matches(parse('x == ""'),record))
        self.assertEqual(record,before)
        self.assertEqual(select({'z':'x==""','n':'x!=""'},record),['z'])
    def test_errors_with_offsets(self):
        cases=[('',0),(' \t',2),('a',1),('a ==',4),('a == "x" b == "y"',9),
               ('(a=="x"',7),('a=="x")',6),('a=="x" &&',9),('a==bare',3),
               ('1a=="x"',0),('a="x"',1),('a=="x" & b=="y"',7),
               ('a=="unterminated',3),('a=="abc\\',3),('a=="x\\q"',5),
               ('a=="x\ny"',5),('a=="x\ry"',5),('a=="x"\u00a0',6),
               ('a=="x" # comment',7),('a=="x" && @',10),
               ('a=="x" || || b=="y"',10),('()',1),('! ',2)]
        for text,pos in cases:
            with self.subTest(text=text):
                with self.assertRaises(ParseError) as caught: parse(text)
                self.assertIsInstance(caught.exception,ValueError)
                self.assertEqual(caught.exception.pos,pos)
        # The lexical error wins over the earlier syntactic error.
        with self.assertRaises(ParseError) as caught: parse('a bare @')
        self.assertEqual(caught.exception.pos,7)
    def test_seeded_round_trip(self):
        r=random.Random(44)
        def tree(depth):
            if depth==0 or r.random()<.3:
                return (r.choice(['eq','ne']),r.choice(['a','route.id','_x']),r.choice(['','x','! &&','λ','a"b','\\','\n']))
            if r.random()<.3: return ('not',tree(depth-1))
            return (r.choice(['and','or']),tree(depth-1),tree(depth-1))
        for _ in range(100):
            ast=tree(5)
            self.assertEqual(parse(render(ast)),ast)
unittest.main()
