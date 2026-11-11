from .codec import decode
def read_entries(stream):
    for line in stream:
        if line.strip():
            yield decode(line)
