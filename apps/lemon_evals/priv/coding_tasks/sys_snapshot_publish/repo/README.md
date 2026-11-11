# Snapshot publisher

The publisher creates named immutable backups and switches a relative `current` symlink. `snapshot.sh` orchestrates copying; `build_manifest.sh DATA` describes the copied files with NUL-delimited digest records. Both are invoked with bash. Filesystem paths are operator-provided. Run `python3 -m unittest discover -s tests`.
