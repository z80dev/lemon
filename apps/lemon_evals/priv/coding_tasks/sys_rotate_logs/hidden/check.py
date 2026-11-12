import pathlib, subprocess, tempfile, os, stat
script='/work/rotate.sh'
def run(*args):
    return subprocess.run(['bash',script,*map(str,args)],capture_output=True)
with tempfile.TemporaryDirectory() as t:
    root=pathlib.Path(t)/'- logs [x]'; root.mkdir()
    names=['api.log','space name.log','line\nname.log','tab\tname.log','-odd.log','.hidden.log','star*.log']
    for name in names:
        p=root/name; p.write_bytes(b'active\x00bytes'); p.chmod(0o640)
        for i in [1,2,3]: pathlib.Path(str(p)+'.'+str(i)).write_text(str(i))
    (root/'nested.log').mkdir(); (root/'other.txt').write_text('safe')
    (root/'link.log').symlink_to(root/'other.txt')
    result=run(root,3); assert result.returncode==0, result.stderr
    assert result.stdout==b''
    for name in names:
        p=root/name
        assert p.read_bytes()==b'' and stat.S_IMODE(p.stat().st_mode)==0o640
        assert pathlib.Path(str(p)+'.1').read_bytes()==b'active\x00bytes'
        assert pathlib.Path(str(p)+'.2').read_text()=='1'
        assert pathlib.Path(str(p)+'.3').read_text()=='2'
    assert (root/'other.txt').read_text()=='safe' and (root/'link.log').is_symlink()
    assert run(root,1).returncode==0
    for name in names: assert pathlib.Path(str(root/name)+'.1').read_bytes()==b''
    empty=root/'empty'; empty.mkdir(); assert run(empty,50).returncode==0
    before={str(p):p.read_bytes() for p in root.iterdir() if p.is_file()}
    for args in [(root,'0'),(root,'01'),(root,'51'),(root,'x'),(root,'999999999999999999999'),(root,),(),(root/'absent','2'),(root/'other.txt','2')]:
        r=run(*args); assert r.returncode==2 and not r.stdout and r.stderr, (args,r)
    assert before=={str(p):p.read_bytes() for p in root.iterdir() if p.is_file()}
    gap=root/'gap.log'; gap.write_text('new'); pathlib.Path(str(gap)+'.2').write_text('old')
    assert run(root,4).returncode==0
    assert pathlib.Path(str(gap)+'.3').read_text()=='old'
    assert not pathlib.Path(str(gap)+'.2').exists()
print('rotation cases passed')
