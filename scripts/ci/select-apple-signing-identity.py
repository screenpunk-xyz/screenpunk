#!/usr/bin/env python3
"""Select exactly one imported Apple signing identity without printing its name."""

import re
import sys


def select(text: str, team_id: str, certificate_type: str,
           requested: str | None = None) -> str:
    if not re.fullmatch(r"[A-Z0-9]{10}", team_id):
        raise ValueError("APPLE_TEAM_ID must be ten uppercase letters or digits")
    if certificate_type not in ("Apple Development", "Apple Distribution", "Developer ID Application"):
        raise ValueError("unsupported signing certificate type")
    identities = re.findall(r'^\s*\d+\)\s+([0-9A-Fa-f]{40})\s+"([^"]+)"', text, re.M)
    matches = {fingerprint.upper() for fingerprint, name in identities
               if name.startswith(certificate_type + ": ")
               and name.endswith(" (" + team_id + ")")
               and (requested is None or requested == fingerprint.upper() or requested == name)}
    if len(matches) != 1:
        raise ValueError("expected exactly one valid imported signing identity for the configured team and type")
    return next(iter(matches))


if __name__ == "__main__":
    try:
        if len(sys.argv) not in (3, 4):
            raise ValueError("usage: select-apple-signing-identity.py TEAM_ID CERTIFICATE_TYPE [REQUESTED_IDENTITY]")
        print(select(sys.stdin.read(), sys.argv[1], sys.argv[2],
                     sys.argv[3] if len(sys.argv) == 4 else None))
    except ValueError as exc:
        print(f"signing preflight: {exc}", file=sys.stderr)
        sys.exit(1)
