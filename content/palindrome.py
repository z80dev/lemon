def is_palindrome(s: str) -> bool:
    """Return True if s is a palindrome, ignoring case and spaces."""
    normalized = "".join(ch.lower() for ch in s if not ch.isspace())
    return normalized == normalized[::-1]
