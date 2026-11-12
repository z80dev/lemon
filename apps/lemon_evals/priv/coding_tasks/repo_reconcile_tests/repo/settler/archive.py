from .codec import encode
from .reader import read_entries
def save(path, entries):
    with open(path,'w') as stream:
        for entry in entries: stream.write(encode(entry)+'\n')
def load(path):
    with open(path) as stream: return list(read_entries(stream))
