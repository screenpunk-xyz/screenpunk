"""Synthetic build-input controls; no actual provider configuration or SDK is accessed."""
import contextlib
import copy
import importlib.util
import io
import json
import os
from pathlib import Path
import plistlib
import stat
import tempfile
import unittest
from unittest import mock

spec = importlib.util.spec_from_file_location("staging_config", Path(__file__).parents[1] / "generate-ios-staging-config.py")
generator = importlib.util.module_from_spec(spec)
spec.loader.exec_module(generator)


def firebase():
    return {"PROJECT_ID": "fixture-project", "API_KEY": "fixture-key-do-not-emit", "GOOGLE_APP_ID": "1:123:ios:fixture",
            "GCM_SENDER_ID": "123", "CLIENT_ID": "123-fixture.apps.googleusercontent.com",
            "REVERSED_CLIENT_ID": "com.googleusercontent.apps.123-fixture", "BUNDLE_ID": "xyz.fixture.ios",
            "IS_ANALYTICS_ENABLED": False}


def template():
    return {"CFBundleIdentifier": "$(PRODUCT_BUNDLE_IDENTIFIER)", "Unrelated": {"value": "preserved"},
            "CFBundleURLTypes": [{"CFBundleURLName": "Calendar", "CFBundleURLSchemes": ["calendar-fixture"]},
                                 {"CFBundleURLName": generator.CLOUD_URL_NAME, "CFBundleURLSchemes": ["$(PLACEHOLDER)"]}]}


def build(data=None, info=None, **overrides):
    arguments = {"expected_project": "fixture-project", "expected_bundle": "xyz.fixture.ios", "api_origin": "https://fixture.invalid/"}
    arguments.update(overrides)
    return generator.build_info(firebase() if data is None else data, template() if info is None else info, **arguments)


class StagingConfigTests(unittest.TestCase):
    def assert_field(self, field, action):
        with self.assertRaises(generator.ConfigurationError) as result:
            action()
        self.assertEqual(str(result.exception), field)
        self.assertNotIn("fixture-key", str(result.exception))

    def test_complete_native_fixture_maps_all_eight_and_preserves_calendar(self):
        original = template()
        result = build(info=original)
        self.assertEqual(len(generator.FIELDS), 7)
        for key, destination in generator.FIELDS.items():
            self.assertEqual(result[destination], firebase()[key])
        self.assertEqual(result["ScreenpunkCloudAPIOrigin"], "https://fixture.invalid/")
        self.assertEqual(result["CFBundleURLTypes"][0], original["CFBundleURLTypes"][0])
        self.assertEqual(result["CFBundleURLTypes"][1], {"CFBundleURLName": generator.CLOUD_URL_NAME,
                                                        "CFBundleURLSchemes": [firebase()["REVERSED_CLIENT_ID"]]})
        self.assertEqual(result["Unrelated"], original["Unrelated"])
        self.assertEqual(original, template())
        self.assertEqual(plistlib.dumps(build(), sort_keys=True), plistlib.dumps(result, sort_keys=True))

    def test_each_required_native_field_is_required_without_fallback(self):
        for key in generator.FIELDS:
            for missing in [None, "", "  ", "$(UNRESOLVED)", "${UNRESOLVED}", 123]:
                with self.subTest(key=key, missing=missing):
                    data = firebase(); data[key] = missing
                    self.assert_field(key, lambda: build(data))
        self.assert_field("ScreenpunkCloudAPIOrigin", lambda: build(api_origin=None))

    def test_exact_project_bundle_sender_app_and_analytics_relationships(self):
        for key, value in [("PROJECT_ID", "other"), ("BUNDLE_ID", "xyz.other"), ("GCM_SENDER_ID", "abc"),
                           ("GOOGLE_APP_ID", "1:456:ios:fixture"), ("GOOGLE_APP_ID", "1:123:ios:"),
                           ("IS_ANALYTICS_ENABLED", True), ("IS_ANALYTICS_ENABLED", 0)]:
            data = firebase(); data[key] = value
            self.assert_field(key, lambda: build(data))
        info = template(); info["CFBundleIdentifier"] = "other"
        self.assert_field("CFBundleIdentifier", lambda: build(info=info))

    def test_client_reverse_and_supplied_values_must_match_native_plist(self):
        for key, value in [("CLIENT_ID", "web-client"), ("CLIENT_ID", ".apps.googleusercontent.com"),
                           ("CLIENT_ID", "space client.apps.googleusercontent.com"), ("REVERSED_CLIENT_ID", "calendar-fixture")]:
            data = firebase(); data[key] = value
            self.assert_field(key, lambda: build(data))
        self.assert_field("CLIENT_ID", lambda: build(google_client_id="other.apps.googleusercontent.com"))
        self.assert_field("REVERSED_CLIENT_ID", lambda: build(callback_scheme="other"))
        self.assertEqual(build(google_client_id=firebase()["CLIENT_ID"], callback_scheme=firebase()["REVERSED_CLIENT_ID"]), build())

    def test_origin_only_https_and_no_guessed_default(self):
        for origin in ["", "http://fixture.invalid", "https://user:pass@fixture.invalid", "https://fixture.invalid/path",
                       "https://fixture.invalid?secret=value", "https://fixture.invalid#fragment", "https:///", 
                       "https://fixture.invalid:bad", "https://fixture.invalid\\path", "https:// fixture.invalid", "https://fixture.invalid?"]:
            with self.subTest(origin=origin):
                self.assert_field("ScreenpunkCloudAPIOrigin", lambda: build(api_origin=origin))
        self.assertEqual(build(api_origin="https://fixture.invalid:443")["ScreenpunkCloudAPIOrigin"], "https://fixture.invalid:443")

    def test_cloud_url_collision_and_duplicate_entry_fail(self):
        info = template(); info["CFBundleURLTypes"][0]["CFBundleURLSchemes"] = [firebase()["REVERSED_CLIENT_ID"]]
        self.assert_field("CFBundleURLSchemes", lambda: build(info=info))
        info = template(); info["CFBundleURLTypes"].append(copy.deepcopy(info["CFBundleURLTypes"][1]))
        self.assert_field("CFBundleURLTypes", lambda: build(info=info))
        for types in [None, {}, ["bad"]]:
            info = template(); info["CFBundleURLTypes"] = types
            self.assert_field("CFBundleURLTypes", lambda: build(info=info))

    def test_private_file_read_rejects_symlink_permissions_and_oversize(self):
        with tempfile.TemporaryDirectory() as root:
            path = Path(root) / "input.plist"; path.write_bytes(plistlib.dumps(firebase())); path.chmod(0o600)
            self.assertEqual(generator.read_plist(path, protected=True, field="FirebasePlist")[0], firebase())
            link = Path(root) / "link"; link.symlink_to(path)
            self.assert_field("FirebasePlist", lambda: generator.read_plist(link, protected=True, field="FirebasePlist"))
            path.chmod(0o644)
            self.assert_field("FirebasePlist", lambda: generator.read_plist(path, protected=True, field="FirebasePlist"))
            path.chmod(0o600); path.write_bytes(b"x" * (generator.MAX_INPUT_BYTES + 1))
            self.assert_field("FirebasePlist", lambda: generator.read_plist(path, protected=True, field="FirebasePlist"))

    def test_atomic_output_is_private_before_content_and_replaces_regular_only(self):
        with tempfile.TemporaryDirectory() as root:
            output = Path(root) / "Info.plist"
            write = os.write
            modes = []
            def observed_write(fd, content):
                modes.append(stat.S_IMODE(os.fstat(fd).st_mode))
                return write(fd, content)
            with mock.patch.object(generator.os, "write", side_effect=observed_write):
                generator.atomic_private_write(output, b"one")
                generator.atomic_private_write(output, b"two")
            self.assertEqual(modes, [0o600, 0o600]); self.assertEqual(output.read_bytes(), b"two")
            self.assertEqual(stat.S_IMODE(output.stat().st_mode), 0o600)
            link = Path(root) / "link"; link.symlink_to(output)
            self.assert_field("Output", lambda: generator.atomic_private_write(link, b"bad"))
            self.assertEqual(output.read_bytes(), b"two")
            self.assert_field("Output", lambda: generator.atomic_private_write(Path(root), b"bad"))

    def test_post_rename_sync_failure_is_reported_without_false_absence_claim(self):
        with tempfile.TemporaryDirectory() as root:
            output = Path(root) / "Info.plist"; sync = os.fsync
            def fail_directory(fd):
                if stat.S_ISDIR(os.fstat(fd).st_mode):
                    raise OSError("fixture-key-do-not-emit")
                sync(fd)
            with mock.patch.object(generator.os, "fsync", side_effect=fail_directory):
                self.assert_field("Output", lambda: generator.atomic_private_write(output, b"candidate"))
            self.assertEqual(output.read_bytes(), b"candidate")
            self.assertEqual(stat.S_IMODE(output.stat().st_mode), 0o600)

    def test_cli_validates_before_output_and_never_echoes_values(self):
        with tempfile.TemporaryDirectory() as root:
            root = Path(root); data = root / "firebase.plist"; info = root / "template.plist"; output = root / "output.plist"; receipt = root / "receipt.json"
            data.write_bytes(plistlib.dumps(firebase())); data.chmod(0o600); info.write_bytes(plistlib.dumps(template()))
            args = ["--firebase-plist", str(data), "--info-template", str(info), "--expected-project", "fixture-project",
                    "--expected-bundle", "xyz.fixture.ios", "--output", str(output), "--receipt", str(receipt)]
            error = io.StringIO()
            with contextlib.redirect_stderr(error):
                self.assertEqual(generator.main(args), 2)
            self.assertEqual(error.getvalue(), "Invalid staging configuration: ScreenpunkCloudAPIOrigin\n")
            self.assertFalse(output.exists()); self.assertFalse(receipt.exists())
            success = io.StringIO()
            with contextlib.redirect_stdout(success):
                self.assertEqual(generator.main(args + ["--api-origin", "https://fixture.invalid"]), 0)
            self.assertNotIn(firebase()["API_KEY"], success.getvalue()); self.assertNotIn(firebase()["CLIENT_ID"], success.getvalue())
            saved = plistlib.loads(output.read_bytes()); self.assertEqual(saved, build(api_origin="https://fixture.invalid"))
            metadata = json.loads(receipt.read_text()); self.assertEqual(len(metadata["validatedFields"]), 8)
            self.assertNotIn(firebase()["API_KEY"], receipt.read_text()); self.assertNotIn(firebase()["CLIENT_ID"], receipt.read_text())
            self.assertEqual(stat.S_IMODE(receipt.stat().st_mode), 0o600)
            original = data.read_bytes()
            with contextlib.redirect_stderr(io.StringIO()):
                self.assertEqual(generator.main(args + ["--api-origin", "https://fixture.invalid", "--output", str(data)]), 2)
            self.assertEqual(data.read_bytes(), original)

    def test_parent_alias_output_cannot_replace_protected_input(self):
        with tempfile.TemporaryDirectory() as root:
            root = Path(root); physical = root / "physical"; physical.mkdir()
            alias = root / "alias"; alias.symlink_to(physical, target_is_directory=True)
            child = physical / "nested"; child.mkdir()
            data = child / "firebase.plist"; info = child / "template.plist"
            data.write_bytes(plistlib.dumps(firebase())); data.chmod(0o600)
            info.write_bytes(plistlib.dumps(template()))
            original = data.read_bytes()
            args = ["--firebase-plist", str(data), "--info-template", str(info), "--expected-project", "fixture-project",
                    "--expected-bundle", "xyz.fixture.ios", "--api-origin", "https://fixture.invalid",
                    "--output", str(alias / "nested" / data.name)]
            with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
                outcome = generator.main(args)
            self.assertEqual(outcome, 2, "A physical-parent alias must reject before writing")
            self.assertEqual(data.read_bytes(), original, "Protected input must remain byte-identical")

    def test_all_artifact_aliases_reject_before_any_writer_call(self):
        cases = ["output-firebase-ancestor", "output-template-ancestor", "receipt-firebase-ancestor",
                 "receipt-template-ancestor", "output-receipt-ancestor", "output-firebase-hardlink",
                 "receipt-template-hardlink", "output-receipt-hardlink"]
        for case in cases:
            with self.subTest(case=case), tempfile.TemporaryDirectory() as root:
                root = Path(root); physical = root / "physical"; physical.mkdir()
                child = physical / "nested"; child.mkdir()
                alias = root / "alias"; alias.symlink_to(physical, target_is_directory=True)
                data = child / "firebase.plist"; info = child / "template.plist"
                data.write_bytes(plistlib.dumps(firebase())); data.chmod(0o600)
                info.write_bytes(plistlib.dumps(template()))
                output = child / "output.plist"; receipt = child / "receipt.json"
                if case == "output-firebase-ancestor": output = alias / "nested" / data.name
                elif case == "output-template-ancestor": output = alias / "nested" / info.name
                elif case == "receipt-firebase-ancestor": receipt = alias / "nested" / data.name
                elif case == "receipt-template-ancestor": receipt = alias / "nested" / info.name
                elif case == "output-receipt-ancestor": receipt = alias / "nested" / output.name
                elif case == "output-firebase-hardlink": os.link(data, output)
                elif case == "receipt-template-hardlink": os.link(info, receipt)
                elif case == "output-receipt-hardlink": output.write_bytes(b"sentinel"); os.link(output, receipt)
                protected = {path: path.read_bytes() for path in [data, info, output, receipt] if path.exists()}
                args = ["--firebase-plist", str(data), "--info-template", str(info), "--expected-project", "fixture-project",
                        "--expected-bundle", "xyz.fixture.ios", "--api-origin", "https://fixture.invalid",
                        "--output", str(output), "--receipt", str(receipt)]
                with mock.patch.object(generator, "write_qualified", wraps=generator.write_qualified) as writer:
                    with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
                        self.assertEqual(generator.main(args), 2)
                    writer.assert_not_called()
                for path, original in protected.items(): self.assertEqual(path.read_bytes(), original)
                self.assertFalse(list(child.glob(".screenpunk-staging-*")))

    def test_qualified_writer_rejects_changed_final_inode_before_effects(self):
        with tempfile.TemporaryDirectory() as root:
            output = Path(root) / "output"; output.write_bytes(b"baseline")
            with generator.QualifiedLocation(output, field="Output", required=False) as location:
                replacement = Path(root) / "replacement"; replacement.write_bytes(b"baseline")
                replacement.replace(output)
                with mock.patch.object(generator.os, "write", wraps=os.write) as write:
                    self.assert_field("Output", lambda: generator.write_qualified(location, b"candidate"))
                    write.assert_not_called()
                self.assertEqual(output.read_bytes(), b"baseline")

    def test_qualified_writer_rechecks_baseline_before_rename(self):
        with tempfile.TemporaryDirectory() as root:
            output = Path(root) / "output"; output.write_bytes(b"baseline")
            sync = os.fsync
            def replace_during_file_sync(fd):
                sync(fd)
                if stat.S_ISREG(os.fstat(fd).st_mode):
                    replacement = Path(root) / "replacement"; replacement.write_bytes(b"external")
                    replacement.replace(output)
            with mock.patch.object(generator.os, "fsync", side_effect=replace_during_file_sync):
                self.assert_field("Output", lambda: generator.atomic_private_write(output, b"candidate"))
            self.assertEqual(output.read_bytes(), b"external")
            self.assertFalse(list(Path(root).glob(".screenpunk-staging-*")))

    def test_unknown_cli_arguments_are_sanitized(self):
        error = io.StringIO()
        with contextlib.redirect_stderr(error):
            self.assertEqual(generator.main(["--secret-value-fixture-key-do-not-emit"]), 2)
        self.assertEqual(error.getvalue(), "Invalid staging configuration: Arguments\n")


if __name__ == "__main__":
    unittest.main()
