"""Single source of truth for how strong a password has to be.

The Flutter app shows a live strength meter, but that check is trivially
bypassed by posting straight at the API, so every endpoint that sets a
password runs this too. Mirrored in lib/utils/password_policy.dart - change
both together.
"""

MIN_LENGTH = 8


def password_error(password: str) -> str | None:
    """Returns a human-readable problem with [password], or None if it passes.

    Rules: at least 8 characters and at least one digit. Kept intentionally
    small - length is what actually defeats brute force, and piling on symbol
    requirements tends to push students toward 'Password1!' patterns.
    """
    if not password or len(password) < MIN_LENGTH:
        return f'Password must be at least {MIN_LENGTH} characters.'
    if not any(char.isdigit() for char in password):
        return 'Password must include at least 1 number.'
    return None
