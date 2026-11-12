import pathlib, subprocess, tempfile, unittest
SCRIPT=pathlib.Path(__file__).resolve().parents[1]/'manifest.sh'
class Manifest(unittest.TestCase):
    def test_roundtrip(self):
        with tempfile.TemporaryDirectory() as d:
            root=pathlib.Path(d)/'root'; root.mkdir(); (root/'a.txt').write_text('hello')
            m=pathlib.Path(d)/'manifest'
            subprocess.run(['bash',str(SCRIPT),'create',str(root),str(m)],check=True)
            r=subprocess.run(['bash',str(SCRIPT),'verify',str(root),str(m)],capture_output=True)
            self.assertEqual((r.returncode,r.stdout),(0,b'OK 1\n'))
