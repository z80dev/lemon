"""Utilities for generating prime numbers with the Sieve of Eratosthenes.

This module exposes a single function, :func:`sieve_of_eratosthenes`, which returns
all prime numbers less than or equal to a user-provided upper bound.
"""

from __future__ import annotations



def sieve_of_eratosthenes(n: int) -> list[int]:
    """Return all prime numbers less than or equal to ``n``.

    This implementation uses the classic **Sieve of Eratosthenes** algorithm:

    1. Assume every number from ``2`` to ``n`` is prime.
    2. Starting at ``2``, mark all multiples of each confirmed prime as composite.
    3. Continue up to ``sqrt(n)``.
    4. Return every index still marked prime.

    The sieve runs in roughly ``O(n log log n)`` time with ``O(n)`` space,
    making it efficient for generating many primes in a bounded range.

    Args:
        n: Inclusive upper bound for prime generation. Must be a non-negative
            integer.

    Returns:
        A list of all prime numbers ``<= n`` in ascending order.

    Raises:
        TypeError: If ``n`` is not an integer.
        ValueError: If ``n`` is negative.

    Examples:
        >>> sieve_of_eratosthenes(10)
        [2, 3, 5, 7]
        >>> len(sieve_of_eratosthenes(10_000))
        1229
    """
    if not isinstance(n, int):
        raise TypeError("n must be an integer")
    if n < 0:
        raise ValueError("n must be non-negative")
    if n < 2:
        return []

    is_prime: list[bool] = [True] * (n + 1)
    is_prime[0] = False
    is_prime[1] = False

    limit: int = int(n**0.5)
    for candidate in range(2, limit + 1):
        if is_prime[candidate]:
            start: int = candidate * candidate
            is_prime[start : n + 1 : candidate] = [False] * (((n - start) // candidate) + 1)

    return [number for number, prime in enumerate(is_prime) if prime]


if __name__ == "__main__":
    primes_up_to_10000: list[int] = sieve_of_eratosthenes(10_000)
    print(f"Found {len(primes_up_to_10000)} primes up to 10000.")
