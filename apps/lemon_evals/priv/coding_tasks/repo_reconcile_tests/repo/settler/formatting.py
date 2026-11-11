def money(cents):
    return ('-' if cents < 0 else '')+f'{abs(cents)//100}.{abs(cents)%100:02d}'
