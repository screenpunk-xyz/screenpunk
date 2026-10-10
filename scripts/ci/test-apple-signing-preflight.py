#!/usr/bin/env python3
import datetime
import hashlib
import importlib.util
import unittest
from pathlib import Path


HERE = Path(__file__).parent


def load(name, file):
    spec = importlib.util.spec_from_file_location(name, HERE / file)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


identity = load("identity", "select-apple-signing-identity.py")
profile = load("profile", "validate-ios-distribution-profile.py")
TEAM = "A1B2C3D4E5"
SHA = "A" * 40
CERT = b"synthetic certificate for matching only"
CERT_SHA = hashlib.sha1(CERT).hexdigest().upper()


class AppleSigningPreflightTests(unittest.TestCase):
    def test_exact_team_type_and_single_identity(self):
        listing = f'  1) {SHA} "Developer ID Application: Example ({TEAM})"\n     1 valid identities found\n'
        self.assertEqual(identity.select(listing, TEAM, "Developer ID Application"), SHA)
        with self.assertRaises(ValueError):
            identity.select(listing, "ZZZZZZZZZZ", "Developer ID Application")
        with self.assertRaises(ValueError):
            identity.select(listing, TEAM, "Apple Distribution")
        with self.assertRaises(ValueError):
            identity.select(listing, TEAM, "Developer ID Application", "wrong identity")
        self.assertEqual(identity.select(listing, TEAM, "Developer ID Application", SHA), SHA)
        second = '  2) ' + 'B' * 40 + f' "Developer ID Application: Other ({TEAM})"\n'
        with self.assertRaises(ValueError):
            identity.select(listing + second, TEAM, "Developer ID Application")

    def test_distribution_profile_matches_team_app_and_certificate(self):
        value = {"TeamIdentifier": [TEAM], "Entitlements": {
            "application-identifier": f"{TEAM}.xyz.screenpunk.ios", "get-task-allow": False},
            "ExpirationDate": datetime.datetime.now(datetime.timezone.utc) + datetime.timedelta(days=30),
            "DeveloperCertificates": [CERT], "UUID": "fixture-uuid", "Name": "fixture"}
        profile.validate(value, TEAM, "xyz.screenpunk.ios", CERT_SHA)
        for changed in (
            {**value, "TeamIdentifier": ["ZZZZZZZZZZ"]},
            {**value, "Entitlements": {**value["Entitlements"], "application-identifier": f"{TEAM}.wrong"}},
            {**value, "Entitlements": {**value["Entitlements"], "get-task-allow": True}},
            {**value, "ExpirationDate": datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(days=1)},
            {**value, "DeveloperCertificates": [b"wrong"]},
        ):
            with self.assertRaises(ValueError):
                profile.validate(changed, TEAM, "xyz.screenpunk.ios", CERT_SHA)


if __name__ == "__main__":
    unittest.main()
