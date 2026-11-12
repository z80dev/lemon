import subprocess
changed=subprocess.check_output(['git','diff','--name-only','HEAD'],text=True).splitlines()
added=subprocess.check_output(['git','ls-files','--others','--exclude-standard'],text=True).splitlines()
assert set(changed+added) <= {'tests/test_reconcile.py'}, 'Only tests/test_reconcile.py may change'
