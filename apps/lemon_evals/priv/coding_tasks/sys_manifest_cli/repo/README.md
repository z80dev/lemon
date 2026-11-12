# Directory manifests

Operators use `bash manifest.sh create ROOT MANIFEST` to record content and `bash manifest.sh verify ROOT MANIFEST` to detect drift. Paths in the record are relative to ROOT; manifest files live outside that directory. The tools `find`, `sort`, and `sha256sum` are available. Run `python3 -m unittest discover -s tests`.
