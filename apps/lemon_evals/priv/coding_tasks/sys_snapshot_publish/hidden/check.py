import pathlib, subprocess, tempfile, hashlib, os, stat
S='/work/snapshot.sh'
def run(*args,env=None): return subprocess.run(['bash',S,*map(str,args)],capture_output=True,env=env)
with tempfile.TemporaryDirectory() as d:
    p=pathlib.Path(d); src=p/'- source'; src.mkdir(); store=p/'backup space'; store.mkdir()
    files={'a':b'\0hello\xff','nested/a b':b'other','-x*':b'q','nl\nline\tfile':b'n','back\\slash':b'b'}
    for name,data in files.items():
        f=src/name; f.parent.mkdir(exist_ok=True,parents=True); f.write_bytes(data); f.chmod(0o640)
    (src/'empty dir').mkdir(); (src/'empty dir').chmod(0o750)
    r=run(src,store,'day_1'); assert (r.returncode,r.stdout)==(0,b'day_1\n'),r.stderr
    data=store/'day_1/data'
    for name,value in files.items():
        assert (data/name).read_bytes()==value
        assert stat.S_IMODE((data/name).stat().st_mode)==0o640
    assert (data/'empty dir').is_dir() and stat.S_IMODE((data/'empty dir').stat().st_mode)==0o750
    expected=b''.join(hashlib.sha256(files[k]).hexdigest().encode()+b'\t'+k.encode()+b'\0' for k in sorted(files,key=lambda x:x.encode()))
    assert (store/'day_1/manifest').read_bytes()==expected
    assert os.readlink(store/'current')=='day_1'
    assert sorted(x.name for x in store.iterdir())==['current','day_1']
    (src/'a').write_bytes(b'changed')
    r=run(src,store,'day_2'); assert r.returncode==0,r.stderr
    assert os.readlink(store/'current')=='day_2' and (store/'day_1/data/a').read_bytes()==files['a']
    baseline=sorted(x.name for x in store.iterdir())
    for args in [(),(src,store),(src,store,'bad/path'),(src,store,''),(src,store,'current'),(src,store,'a'*33),(src,store,'day_1'),(p/'missing',store,'x'),(src,p/'missing','x')]:
        r=run(*args); assert r.returncode==2 and not r.stdout and r.stderr,(args,r)
        assert sorted(x.name for x in store.iterdir())==baseline
    (src/'link').symlink_to(src/'a')
    r=run(src,store,'reject'); assert r.returncode==2 and not r.stdout
    (src/'link').unlink()
    (store/'broken').symlink_to('missing')
    assert run(src,store,'broken').returncode==2
    (store/'broken').unlink()
    (store/'.lock').mkdir(); (store/'.lock/owner').write_text('other')
    r=run(src,store,'locked'); assert r.returncode==3 and not r.stdout and r.stderr
    assert (store/'.lock/owner').read_text()=='other'
    (store/'.lock/owner').unlink(); (store/'.lock').rmdir()
    fake=p/'bin'; fake.mkdir()
    for program in ['cp','sha256sum']:
        exe=fake/program; exe.write_text('#!/bin/bash\nexit 19\n'); exe.chmod(0o755)
        env=dict(os.environ,PATH=str(fake)+':'+os.environ['PATH'])
        r=run(src,store,'failed',env=env)
        assert r.returncode==1 and not r.stdout and r.stderr,(program,r)
        assert sorted(x.name for x in store.iterdir())==baseline
        assert os.readlink(store/'current')=='day_2'
        exe.unlink()
print('snapshot cases passed')
