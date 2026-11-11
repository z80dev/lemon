import re


def slug(text):
    return re.sub(r'[^a-z0-9]+', '-', text.lower()).strip('-')
