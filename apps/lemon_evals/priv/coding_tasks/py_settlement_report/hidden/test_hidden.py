import copy
import json
import subprocess
import sys
import unittest
from settlement.report import build_report

def charge(id,merchant,amount,time,status='settled'):
    return dict(id=id,merchant=merchant,amount_cents=amount,settled_at=time,status=status)
def refund(id,amount,time):
    return dict(charge_id=id,amount_cents=amount,posted_at=time)
def row(merchant,gross,refunds):
    return dict(merchant=merchant,gross_cents=gross,refund_cents=refunds,net_cents=gross-refunds)

class Contract(unittest.TestCase):
    def test_real_command(self):
        result=subprocess.run([sys.executable,'-m','settlement','data/sample.json','--month','2025-03','--zone','America/New_York'],capture_output=True,text=True)
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertEqual(result.stderr,'')
        self.assertEqual(len(result.stdout.splitlines()),1)
        self.assertEqual(json.loads(result.stdout),dict(month='2025-03',zone='America/New_York',merchants=[row('Harbor',10000,2500),row('Willow',0,500)]))
    def test_refund_join_and_zero(self):
        doc=dict(charges=[charge('a','Z',0,'2024-12-01T10:00:00Z'),charge('b','A',5,'2025-01-01T12:00:00Z'),charge('p','P',1,None,'pending'),charge('c','Empty',100,'2024-11-01T00:00:00Z')],refunds=[refund('a',8,'2025-01-02T12:00:00Z'),refund('a',3,'2025-01-02T12:00:00Z'),refund('b',5,'2025-01-02T12:00:00Z'),refund('p',20,'2025-01-01T12:00:00Z'),refund('missing',20,'2025-01-01T12:00:00Z')])
        before=copy.deepcopy(doc)
        self.assertEqual(build_report(doc,'2025-01','UTC')['merchants'],[row('A',5,5),row('Z',0,11)])
        self.assertEqual(doc,before)
    def test_offset_and_dst_boundaries(self):
        doc=dict(charges=[charge('a','A',10,'2025-04-01T00:30:00+02:00'),charge('b','B',20,'2025-03-31T23:30:00-04:00'),charge('c','C',0,'2025-03-09T03:30:00-04:00')],refunds=[refund('a',2,'2025-04-01T00:30:00+02:00'),refund('b',1,'2025-04-01T04:00:00Z')])
        self.assertEqual(build_report(doc,'2025-03','UTC')['merchants'],[row('A',10,2),row('C',0,0)])
        self.assertEqual(build_report(doc,'2025-03','America/New_York')['merchants'],[row('A',10,2),row('B',20,0),row('C',0,0)])
        self.assertEqual(build_report(doc,'2025-04','UTC')['merchants'],[row('B',20,1)])
unittest.main()
