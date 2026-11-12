import pathlib, subprocess, tempfile, unittest
SCRIPT=pathlib.Path(__file__).resolve().parents[1]/'run_plan.sh'
class Runner(unittest.TestCase):
    def test_success(self):
        with tempfile.TemporaryDirectory() as d:
            p=pathlib.Path(d); jobs=p/'jobs'; jobs.mkdir(); (jobs/'ok.sh').write_text('printf hello')
            plan=p/'plan'; plan.write_text('one\t-\tok.sh\n'); out=p/'results'
            r=subprocess.run(['bash',str(SCRIPT),str(plan),str(jobs),str(out)],capture_output=True)
            self.assertEqual(r.returncode,0,r.stderr)
            self.assertEqual((out/'status.tsv').read_text(),'one\tsucceeded\t0\n')
            self.assertEqual((out/'one.out').read_text(),'hello')
