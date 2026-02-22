"""Prime number generation using the Sieve of Eratosthenes.

This module provides a single utility function, :func:`sieve_of_eratosthenes`,
for efficiently computing all prime numbers less than or equal to a specified
upper bound.
"""

from __future__ import annotations


def sieve_of_eratosthenes(n: int = 10_000) -> list[int]:
    """Return all prime numbers less than or equal to ``n``.

    This implementation uses the classic Sieve of Eratosthenes algorithm,
    which marks multiples of each discovered prime number starting at
    ``p * p`` (because smaller multiples have already been handled by
    smaller primes).

    Args:
        n: Inclusive upper bound for prime search. Defaults to ``10_000``.

    Returns:
        A list of prime integers in ascending order from ``2`` to ``n``.
        Returns an empty list when ``n < 2``.

    Raises:
        TypeError: If ``n`` is not an integer.

    Examples:
        >>> sieve_of_eratosthenes(10)
        [2, 3, 5, 7]
        >>> sieve_of_eratosthenes(1)
        []
    """
    if not isinstance(n, int):
        raise TypeError("n must be an integer")

    if n < 2:
        return []

    # True means "assume prime" until proven composite.
    is_prime: list[bool] = [True] * (n + 1)
    is_prime[0] = False
    is_prime[1] = False

    limit: int = int(n**0.5)
    for candidate in range(2, limit + 1):
        if is_prime[candidate]:
            start = candidate * candidate
            step = candidate
            is_prime[start : n + 1 : step] = [False] * (((n - start) // step) + 1)

    return [number for number, prime in enumerate(is_prime) if prime]
