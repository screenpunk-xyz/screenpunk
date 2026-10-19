#!/usr/bin/env python3
"""Generate a protected build-input plist; never initializes a provider or enrolls a device."""
import argparse
import copy
from contextlib import ExitStack
import hashlib
import json
import os
from pathlib import Path
import plistlib
import stat
import sys
import secrets
from urllib.parse import urlsplit

MAX_INPUT_BYTES = 1024 * 1024
CLOUD_URL_NAME = "Screenpunk Cloud OAuth"
FIELDS = {
    "PROJECT_ID": "ScreenpunkCloudFirebaseProjectID",
    "API_KEY": "ScreenpunkCloudFirebaseAPIKey",
    "GOOGLE_APP_ID": "ScreenpunkCloudFirebaseAppID",
    "GCM_SENDER_ID": "ScreenpunkCloudFirebaseSenderID",
    "CLIENT_ID": "ScreenpunkCloudGoogleClientID",
    "REVERSED_CLIENT_ID": "ScreenpunkCloudGoogleCallbackScheme",
    "BUNDLE_ID": "ScreenpunkCloudBundleID",
}


class ConfigurationError(Exception):
    """Only a fixed field name is exposed, never its value or an underlying error."""
    def __init__(self, field):
        self.field = field
        super().__init__(field)


def text(mapping, key):
    value = mapping.get(key)
    if (not isinstance(value, str) or not value or value != value.strip()
            or "$(" in value or "${" in value or any(ord(c) < 32 for c in value)):
        raise ConfigurationError(key)
    return value


def build_info(firebase, template, *, expected_project, expected_bundle, api_origin,
               google_client_id=None, callback_scheme=None):
    """Pure validation; no fallback from Calendar/web clients or implicit endpoint."""
    if not isinstance(firebase, dict):
        raise ConfigurationError("FirebasePlist")
    if not isinstance(template, dict):
        raise ConfigurationError("InfoTemplate")
    values = {key: text(firebase, key) for key in FIELDS}
    if values["PROJECT_ID"] != text({"PROJECT_ID": expected_project}, "PROJECT_ID"):
        raise ConfigurationError("PROJECT_ID")
    if values["BUNDLE_ID"] != text({"BUNDLE_ID": expected_bundle}, "BUNDLE_ID"):
        raise ConfigurationError("BUNDLE_ID")
    template_bundle = template.get("CFBundleIdentifier")
    if template_bundle is not None and template_bundle not in (expected_bundle, "$(PRODUCT_BUNDLE_IDENTIFIER)"):
        raise ConfigurationError("CFBundleIdentifier")
    if firebase.get("IS_ANALYTICS_ENABLED") is not False:
        raise ConfigurationError("IS_ANALYTICS_ENABLED")
    sender = values["GCM_SENDER_ID"]
    if not sender.isascii() or not sender.isdigit():
        raise ConfigurationError("GCM_SENDER_ID")
    prefix = "1:" + sender + ":ios:"
    if not values["GOOGLE_APP_ID"].startswith(prefix) or not values["GOOGLE_APP_ID"][len(prefix):]:
        raise ConfigurationError("GOOGLE_APP_ID")
    for supplied, key in [(google_client_id, "CLIENT_ID"), (callback_scheme, "REVERSED_CLIENT_ID")]:
        if supplied is not None and supplied != values[key]:
            raise ConfigurationError(key)
    client = values["CLIENT_ID"]
    suffix = ".apps.googleusercontent.com"
    stem = client.removesuffix(suffix)
    if not client.endswith(suffix) or not stem or not all(c.isascii() and (c.isalnum() or c == "-") for c in stem):
        raise ConfigurationError("CLIENT_ID")
    callback = values["REVERSED_CLIENT_ID"]
    if callback != "com.googleusercontent.apps." + stem:
        raise ConfigurationError("REVERSED_CLIENT_ID")
    origin = text({"ScreenpunkCloudAPIOrigin": api_origin}, "ScreenpunkCloudAPIOrigin")
    try:
        parsed = urlsplit(origin)
        # Match the native origin-only contract, with conservative ASCII spelling.
        if (not origin.isascii() or any(c.isspace() for c in origin) or "\\" in origin
                or parsed.scheme != "https" or not parsed.hostname
                or parsed.username is not None or parsed.password is not None
                or "?" in origin or "#" in origin or parsed.path not in ("", "/")):
            raise ValueError()
        _ = parsed.port
    except ValueError:
        raise ConfigurationError("ScreenpunkCloudAPIOrigin") from None
    types = template.get("CFBundleURLTypes", [])
    if not isinstance(types, list):
        raise ConfigurationError("CFBundleURLTypes")
    retained = []
    cloud_count = 0
    for item in types:
        if not isinstance(item, dict):
            raise ConfigurationError("CFBundleURLTypes")
        if item.get("CFBundleURLName") == CLOUD_URL_NAME:
            cloud_count += 1
            continue
        schemes = item.get("CFBundleURLSchemes", [])
        if not isinstance(schemes, list) or not all(isinstance(s, str) for s in schemes):
            raise ConfigurationError("CFBundleURLTypes")
        if callback in schemes:
            raise ConfigurationError("CFBundleURLSchemes")
        retained.append(copy.deepcopy(item))
    if cloud_count > 1:
        raise ConfigurationError("CFBundleURLTypes")
    result = copy.deepcopy(template)
    result.update({destination: values[source] for source, destination in FIELDS.items()})
    result["ScreenpunkCloudAPIOrigin"] = origin
    result["CFBundleURLTypes"] = retained + [{"CFBundleURLName": CLOUD_URL_NAME, "CFBundleURLSchemes": [callback]}]
    return result


class QualifiedLocation:
    """Held physical parent plus final-node baseline; not cross-process exclusion."""
    def __init__(self, path, *, field, required):
        self.field = field
        self.directory = None
        try:
            path = Path(path)
            self.name = path.name
            if not self.name or self.name in (".", ".."):
                raise ConfigurationError(field)
            physical_parent = path.parent.resolve(strict=True)
            self.directory = os.open(physical_parent, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
            parent = os.fstat(self.directory)
            self.location_identity = (parent.st_dev, parent.st_ino, os.fsencode(self.name))
            self.baseline = self.node_identity()
            if required and self.baseline is None:
                raise ConfigurationError(field)
        except ConfigurationError:
            self.close()
            raise
        except Exception:
            self.close()
            raise ConfigurationError(field) from None

    def node_identity(self):
        try:
            node = os.stat(self.name, dir_fd=self.directory, follow_symlinks=False)
        except FileNotFoundError:
            return None
        if not stat.S_ISREG(node.st_mode):
            raise ConfigurationError(self.field)
        return (node.st_dev, node.st_ino)

    def verify_baseline(self):
        if self.node_identity() != self.baseline:
            raise ConfigurationError(self.field)

    def close(self):
        if self.directory is not None:
            os.close(self.directory)
            self.directory = None

    def __enter__(self):
        return self

    def __exit__(self, *_):
        self.close()


def reject_aliases(locations):
    """Reject alternate parent spellings and hardlinks before any output effect."""
    identities = set()
    nodes = set()
    for location in locations:
        if location.location_identity in identities:
            raise ConfigurationError("Output")
        identities.add(location.location_identity)
        if location.baseline is not None:
            if location.baseline in nodes:
                raise ConfigurationError("Output")
            nodes.add(location.baseline)


def read_qualified_plist(location, *, protected):
    fd = None
    try:
        location.verify_baseline()
        fd = os.open(location.name, os.O_RDONLY | os.O_NOFOLLOW, dir_fd=location.directory)
        info = os.fstat(fd)
        if ((info.st_dev, info.st_ino) != location.baseline or not stat.S_ISREG(info.st_mode)
                or (protected and stat.S_IMODE(info.st_mode) != 0o600) or info.st_size > MAX_INPUT_BYTES):
            raise ConfigurationError(location.field)
        chunks = bytearray()
        while len(chunks) <= MAX_INPUT_BYTES:
            block = os.read(fd, min(65536, MAX_INPUT_BYTES + 1 - len(chunks)))
            if not block:
                break
            chunks.extend(block)
        if len(chunks) > MAX_INPUT_BYTES:
            raise ConfigurationError(location.field)
        location.verify_baseline()
        raw = bytes(chunks)
        parsed = plistlib.loads(raw)
        if not isinstance(parsed, dict):
            raise ConfigurationError(location.field)
        return parsed, hashlib.sha256(raw).hexdigest()
    except ConfigurationError:
        raise
    except Exception:
        raise ConfigurationError(location.field) from None
    finally:
        if fd is not None:
            os.close(fd)


def read_plist(path, *, protected, field):
    with QualifiedLocation(path, field=field, required=True) as location:
        return read_qualified_plist(location, protected=protected)


def write_qualified(location, content):
    """Use the retained parent only. Post-rename errors are not rolled back."""
    fd = None
    scratch = None
    try:
        location.verify_baseline()
        for _ in range(16):
            name = ".screenpunk-staging-" + secrets.token_hex(16)
            try:
                fd = os.open(name, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600, dir_fd=location.directory)
                scratch = name
                break
            except FileExistsError:
                continue
        if fd is None:
            raise ConfigurationError(location.field)
        os.fchmod(fd, 0o600)
        if stat.S_IMODE(os.fstat(fd).st_mode) != 0o600:
            raise ConfigurationError(location.field)
        offset = 0
        while offset < len(content):
            written = os.write(fd, content[offset:])
            if written <= 0:
                raise ConfigurationError(location.field)
            offset += written
        os.fsync(fd)
        os.close(fd)
        fd = None
        location.verify_baseline()
        os.replace(scratch, location.name, src_dir_fd=location.directory, dst_dir_fd=location.directory)
        scratch = None
        os.fsync(location.directory)
        node = os.stat(location.name, dir_fd=location.directory, follow_symlinks=False)
        if not stat.S_ISREG(node.st_mode) or stat.S_IMODE(node.st_mode) != 0o600:
            raise ConfigurationError(location.field)
    except ConfigurationError:
        raise
    except Exception:
        raise ConfigurationError(location.field) from None
    finally:
        if fd is not None:
            os.close(fd)
        if scratch is not None:
            try:
                os.unlink(scratch, dir_fd=location.directory)
            except OSError:
                pass


def atomic_private_write(path, content, *, field="Output"):
    with QualifiedLocation(path, field=field, required=False) as location:
        write_qualified(location, content)


class SanitizedParser(argparse.ArgumentParser):
    def error(self, message):
        raise ConfigurationError("Arguments")


def main(argv=None):
    parser = SanitizedParser(description=__doc__)
    for flag in ["firebase-plist", "info-template", "expected-project", "expected-bundle", "api-origin", "output"]:
        parser.add_argument("--" + flag)
    parser.add_argument("--google-client-id")
    parser.add_argument("--callback-scheme")
    parser.add_argument("--receipt")
    try:
        args = parser.parse_args(argv)
        for attribute, field in [("firebase_plist", "FirebasePlist"), ("info_template", "InfoTemplate"),
                                 ("expected_project", "PROJECT_ID"), ("expected_bundle", "BUNDLE_ID"),
                                 ("api_origin", "ScreenpunkCloudAPIOrigin"), ("output", "Output")]:
            if not getattr(args, attribute):
                raise ConfigurationError(field)
        with ExitStack() as stack:
            firebase_location = stack.enter_context(QualifiedLocation(args.firebase_plist, field="FirebasePlist", required=True))
            template_location = stack.enter_context(QualifiedLocation(args.info_template, field="InfoTemplate", required=True))
            output_location = stack.enter_context(QualifiedLocation(args.output, field="Output", required=False))
            receipt_location = stack.enter_context(QualifiedLocation(args.receipt, field="Receipt", required=False)) if args.receipt else None
            locations = [firebase_location, template_location, output_location] + ([receipt_location] if receipt_location else [])
            reject_aliases(locations)
            firebase, firebase_hash = read_qualified_plist(firebase_location, protected=True)
            template, template_hash = read_qualified_plist(template_location, protected=False)
            info = build_info(firebase, template, expected_project=args.expected_project, expected_bundle=args.expected_bundle,
                              api_origin=args.api_origin, google_client_id=args.google_client_id, callback_scheme=args.callback_scheme)
            encoded = plistlib.dumps(info, fmt=plistlib.FMT_XML, sort_keys=True)
            write_qualified(output_location, encoded)
            if receipt_location:
                receipt = {"firebaseInputSha256": firebase_hash, "templateSha256": template_hash,
                           "outputSha256": hashlib.sha256(encoded).hexdigest(), "mode": "0600",
                           "validatedFields": sorted(list(FIELDS.values()) + ["ScreenpunkCloudAPIOrigin"])}
                write_qualified(receipt_location, (json.dumps(receipt, sort_keys=True, indent=2) + "\n").encode())
        print("Staging configuration generated; provider activation and signing remain separate.")
        return 0
    except ConfigurationError as error:
        print("Invalid staging configuration: " + error.field, file=sys.stderr)
        return 2
    except Exception:
        print("Invalid staging configuration: Arguments", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
