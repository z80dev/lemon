import unittest
from slug import slug
class SlugTest(unittest.TestCase):
 def test_slug(self):
  self.assertEqual(slug(' Hello,   World!! '), 'hello-world')
  self.assertEqual(slug('---'), '')
if __name__ == '__main__': unittest.main()
