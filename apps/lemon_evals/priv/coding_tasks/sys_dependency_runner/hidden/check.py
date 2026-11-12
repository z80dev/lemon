import pathlib, subprocess, tempfile, os, shlex
S='/work/run_plan.sh'
def run(*args): return subprocess.run(['bash',S,*map(str,args)],capture_output=True)
with tempfile.TemporaryDirectory() as d:
    p=pathlib.Path(d); jobs=p/'- jobs'; jobs.mkdir(); trace=p/'trace'; plan=p/'plan'; out=p/'results'
    names={'later':'dir/a b.sh','root':'-root.sh','bad':'bad[*].sh','child':'child.sh','free':'é.sh','deep':'deep.sh'}
    for id,name in names.items():
        f=jobs/name; f.parent.mkdir(parents=True,exist_ok=True)
        f.write_text('printf "%s\\n" '+shlex.quote(id)+' >> '+shlex.quote(str(trace))+'\nprintf "out '+id+'"\nprintf "err '+id+'" >&2\n'+('exit 7\n' if id=='bad' else 'test "$(pwd)" = '+shlex.quote(str(jobs))+'\nif read -r input; then exit 9; fi\nexit 0\n'))
    rows=[('later','root'),('bad','root'),('child','bad'),('root','-'),('free','-'),('deep','child')]
    plan.write_text('\n'.join(id+'\t'+dep+'\t'+names[id] for id,dep in rows))
    r=run(plan,jobs,out); assert (r.returncode,r.stdout)==(1,b''),r.stderr
    assert trace.read_text().splitlines()==['root','later','bad','free'],trace.read_text()
    expected='later\tsucceeded\t0\nbad\tfailed\t7\nchild\tblocked\t-\nroot\tsucceeded\t0\nfree\tsucceeded\t0\ndeep\tblocked\t-\n'
    assert (out/'status.tsv').read_text()==expected
    for id in ['root','later','bad','free']:
        assert (out/(id+'.out')).read_text()=='out '+id
        assert (out/(id+'.err')).read_text()=='err '+id
    assert not (out/'child.out').exists() and not (out/'deep.err').exists()
    # Invalid plans must not execute even their first independent row.
    valid='root\t-\t-root.sh\n'
    invalids=['x\ty\t-root.sh','root\t-\t-root.sh\nroot\t-\t-root.sh','x\tx\t-root.sh','x\ty\t-root.sh\ny\tx\t-root.sh','x\troot,root\t-root.sh','x\troot,\t-root.sh','x\t-\t../outside','x\t-\t/absolute','x\t-\tdir//a b.sh','x\t-\t./-root.sh','X\t-\t-root.sh','x\t-\tmissing','x\t\t-root.sh','\n','x\t-\t-root.sh\textra']
    for text in invalids:
        plan.write_text(valid+text); dest=p/'reject'
        before=trace.read_bytes(); r=run(plan,jobs,dest)
        assert r.returncode==2 and r.stderr and not r.stdout,(text,r)
        assert not dest.exists() and trace.read_bytes()==before
    (jobs/'link').symlink_to(jobs/'-root.sh'); plan.write_text('x\t-\tlink')
    assert run(plan,jobs,p/'reject').returncode==2
    plan.write_text(valid)
    before=trace.read_bytes(); assert run(plan,jobs,out).returncode==2; assert trace.read_bytes()==before
    for args in [(),(plan,jobs),(p/'missing',jobs,p/'reject'),(plan,p/'missing',p/'reject')]:
        r=run(*args); assert r.returncode==2 and not r.stdout and r.stderr
    plan.write_text(''); empty=p/'empty'; empty.mkdir(); r=run(plan,jobs,empty)
    assert (r.returncode,r.stdout)==(0,b'') and (empty/'status.tsv').read_bytes()==b'',r.stderr
    plan.write_text('x\t-\t-root.sh\ny\t-\t-root.sh\nz\tx,y\t-root.sh\n'); success=p/'success'
    r=run(plan,jobs,success); assert r.returncode==0,r.stderr
    assert (success/'status.tsv').read_text()=='x\tsucceeded\t0\ny\tsucceeded\t0\nz\tsucceeded\t0\n'
print('dependency runner cases passed')
