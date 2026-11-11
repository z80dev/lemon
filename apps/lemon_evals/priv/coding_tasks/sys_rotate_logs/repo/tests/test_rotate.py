import pathlib, subprocess, tempfile, unittest
SCRIPT = pathlib.Path(__file__).resolve().parents[1] / 'rotate.sh'
class Rotation(unittest.TestCase):
    def test_basic(self):
        with tempfile.TemporaryDirectory() as d:
            p=pathlib.Path(d)/'server.log'; p.write_text('hello')
            subprocess.run(['bash',str(SCRIPT),d,'2'],check=True)
            self.assertEqual(p.read_text(),'')
            self.assertEqual(pathlib.Path(str(p)+'.1').read_text(),'hello')
