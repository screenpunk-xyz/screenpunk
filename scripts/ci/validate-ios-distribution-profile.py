#!/usr/bin/env python3
"""Fail closed on a mismatched iOS distribution profile; never print its payload."""

import datetime
import hashlib
import plistlib
import re
import sys
from pathlib import Path


def validate(profile: dict, team_id: str, bundle_id: str, identity_sha1: str) -> None:
    if not re.fullmatch(r"[A-Z0-9]{10}", team_id):
        raise ValueError("invalid configured team ID")
    if not re.fullmatch(r"[A-F0-9]{40}", identity_sha1):
        raise ValueError("invalid signing identity fingerprint")
    if profile.get("TeamIdentifier") != [team_id]:
        raise ValueError("profile team does not match")
    entitlements = profile.get("Entitlements")
    if not isinstance(entitlements, dict):
        raise ValueError("profile entitlements missing")
    if entitlements.get("application-identifier") != f"{team_id}.{bundle_id}":
        raise ValueError("profile app identifier does not match")
    if entitlements.get("get-task-allow") is not False:
        raise ValueError("profile is not a distribution profile")
    expires = profile.get("ExpirationDate")
    if not isinstance(expires, datetime.datetime):
        raise ValueError("profile is expired or has no expiration")
    if expires.tzinfo is None:
        expires = expires.replace(tzinfo=datetime.timezone.utc)
    if expires <= datetime.datetime.now(datetime.timezone.utc):
        raise ValueError("profile is expired or has no expiration")
    certificates = profile.get("DeveloperCertificates")
    if not isinstance(certificates, list) or not any(
        isinstance(cert, bytes) and hashlib.sha1(cert).hexdigest().upper() == identity_sha1
        for cert in certificates
    ):
        raise ValueError("profile does not include the imported signing certificate")
    if not isinstance(profile.get("UUID"), str) or not isinstance(profile.get("Name"), str):
        raise ValueError("profile name or UUID missing")


if __name__ == "__main__":
    try:
        if len(sys.argv) != 5:
            raise ValueError("usage: validate-ios-distribution-profile.py PLIST TEAM_ID BUNDLE_ID IDENTITY_SHA1")
        with Path(sys.argv[1]).open("rb") as stream:
            profile = plistlib.load(stream)
        validate(profile, sys.argv[2], sys.argv[3], sys.argv[4])
        print("iOS profile matches the configured team, app, distribution mode and signing certificate")
    except (OSError, plistlib.InvalidFileException, ValueError) as exc:
        print(f"signing preflight: {exc}", file=sys.stderr)
        sys.exit(1)
