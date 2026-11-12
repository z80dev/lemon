import pathlib, subprocess, tempfile, hashlib
S='/work/manifest.sh'
def run(*args): return subprocess.run(['bash',S,*map(str,args)],capture_output=True)
with tempfile.TemporaryDirectory() as d:
    p=pathlib.Path(d); root=p/'- root'; root.mkdir(); m=p/'manifest'
    assert run('create',root,m).returncode==0 and m.read_bytes()==b''
    r=run('verify',root,m); assert (r.returncode,r.stdout)==(0,b'OK 0\n'),r
    files={'- a':b'\0binary\xff','nested/a b':b'one','z*?':b'two','a\\b':b'three','é':b'four'}
    for name, data in files.items():
        f=root/name; f.parent.mkdir(parents=True,exist_ok=True); f.write_bytes(data)
    (root/'link').symlink_to(root/'- a'); (root/'dirlink').symlink_to(root/'nested',target_is_directory=True)
    r=run('create',root,m); assert r.returncode==0 and r.stdout==b'',r.stderr
    expected=b''.join(hashlib.sha256(files[k]).hexdigest().encode()+b'\t'+k.encode()+b'\n' for k in sorted(files,key=lambda x:x.encode()))
    assert m.read_bytes()==expected,(m.read_bytes(),expected)
    r=run('verify',root,m); assert (r.returncode,r.stdout)==(0,b'OK 5\n'),r.stderr
    m.write_bytes(b'\n'.join(reversed(expected.rstrip(b'\n').split(b'\n'))))
    assert run('verify',root,m).returncode==0
    m.write_bytes(expected)
    for change in ['modify','extra','missing','symlink']:
        f=root/'- a'
        if change=='modify': f.write_bytes(b'changed')
        elif change=='extra': (root/'extra').write_text('x')
        elif change=='missing': f.unlink()
        else: f.unlink(); f.symlink_to(root/'z*?')
        r=run('verify',root,m); assert (r.returncode,r.stdout)==(1,b'MISMATCH\n'),(change,r.stderr)
        if f.is_symlink(): f.unlink()
        f.write_bytes(files['- a']); (root/'extra').unlink(missing_ok=True)
    good=hashlib.sha256(b'x').hexdigest()
    bads=['bad\tx',good+'\t',good+'\t/x',good+'\ta/../x',good+'\t./x',good+'\ta//x',good+'\tx\ty',good+'\tx\n'+good+'\tx',good.upper()+'\tx','\n']
    for body in bads:
        m.write_text(body)
        r=run('verify',root,m); assert r.returncode==2 and not r.stdout and r.stderr,(body,r)
    for args in [(),('bogus',root,m),('create',root),('create',p/'absent',m),('verify',root,p/'absent'),('verify',root,root)]:
        r=run(*args); assert r.returncode==2 and not r.stdout and r.stderr,(args,r)
print('manifest cases passed')
