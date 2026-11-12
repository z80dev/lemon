# Configpeek

Inspect one JSON configuration value without starting the service:

```sh
python3 -m configpeek settings.json database.host
```

The utility is split into a JSON file loader, reusable dotted-key resolver, and
argparse command adapter. It prints JSON so output can be piped into other tools.
Only the Python standard library is needed. The old resolver conflates absent
configuration and disabled settings; preserve the command and reusable APIs when
fixing that behavior.

Run tests: `python3 -m unittest discover -s tests -v`.
