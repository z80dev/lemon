import pathlib, subprocess, tempfile, unittest
SCRIPT=pathlib.Path(__file__).resolve().parents[1]/'snapshot.sh'
class Snapshot(unittest.TestCase):
    def test_publish(self):
        with tempfile.TemporaryDirectory() as d:
            p=pathlib.Path(d); src=p/'src'; src.mkdir(); store=p/'store'; store.mkdir()
            (src/'data').write_text('hello')
            r=subprocess.run(['bash',str(SCRIPT),str(src),str(store),'first'],capture_output=True)
            self.assertEqual((r.returncode,r.stdout),(0,b'first\n'))
            self.assertEqual((store/'first/data/data').read_text(),'hello')
            self.assertEqual((store/'current').readlink(),pathlib.Path('first'))
