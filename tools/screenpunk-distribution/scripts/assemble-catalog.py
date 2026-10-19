#!/usr/bin/env python3
"""Make the exact offline USTAR and signed M0 catalog consumed by the CLI."""
import base64
import hashlib
import json
import os
import pathlib
import stat
import subprocess
import sys
import tarfile
import tempfile
import unicodedata

ENTRY = "authoring-1.0.0-darwin-arm64"
KEY_ID = "screenpunk-release-2026-09"
TEAM = "77KASWDGM6"
EXECUTABLES = {
    "bin/node": "xyz.screenpunk.authoring.node",
    "node_modules/@esbuild/darwin-arm64/bin/esbuild": "xyz.screenpunk.authoring.esbuild",
    "node_modules/fsevents/fsevents.node": "xyz.screenpunk.authoring.fsevents",
    "Host/ScreenpunkBuildHost.app/Contents/MacOS/ScreenpunkBuildHost": "xyz.screenpunk.build-host",
    "Host/ScreenpunkBuildHost.app/Contents/XPCServices/ScreenpunkBuildService.xpc/Contents/MacOS/ScreenpunkBuildService": "xyz.screenpunk.build-service",
}


def digest(path):
    sha = hashlib.sha256()
    with open(path, "rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            sha.update(chunk)
    return sha.hexdigest()


def typed(value):
    def length(n):
        if n < 0 or n > 0x7fffffffffffffff:
            raise ValueError("Invalid M0 length")
        return n.to_bytes(8, "big")
    if value is None:
        return b"n"
    if value is True:
        return b"t"
    if value is False:
        return b"f"
    if isinstance(value, int):
        return b"i" + length(value)
    if isinstance(value, str):
        data = value.encode("utf-8")
        return b"s" + length(len(data)) + data
    if isinstance(value, list):
        return b"a" + length(len(value)) + b"".join(map(typed, value))
    if isinstance(value, dict):
        keys = sorted(value, key=lambda key: key.encode("utf-8"))
        return b"o" + length(len(keys)) + b"".join(typed(k) + typed(value[k]) for k in keys)
    raise TypeError(type(value))


def regular_members(root):
    files = []
    for base, dirs, names in os.walk(root, followlinks=False):
        for name in dirs + names:
            path = pathlib.Path(base) / name
            mode = path.lstat().st_mode
            if stat.S_ISLNK(mode) or not (stat.S_ISDIR(mode) or stat.S_ISREG(mode)):
                raise ValueError(f"Unsafe unit member: {path}")
        for name in names:
            path = pathlib.Path(base) / name
            relative = path.relative_to(root).as_posix()
            if relative != unicodedata.normalize("NFC", relative):
                raise ValueError(f"Non-normalized member: {relative}")
            files.append((relative, path))
    return sorted(files, key=lambda item: item[0].encode("utf-8"))


def main():
    if len(sys.argv) != 6:
        sys.exit("usage: assemble-catalog.py UNIT TAR ENVELOPE PRIVATE_KEY SIGNER_BINARY")
    unit, tar_path, envelope_path, private_key, signer = map(pathlib.Path, sys.argv[1:])
    members = regular_members(unit)
    if not members or len(members) > 100000:
        raise ValueError("Invalid unit file count")
    inventory = []
    expanded = 0
    with tarfile.open(tar_path, "w", format=tarfile.USTAR_FORMAT) as archive:
        for relative, path in members:
            size = path.stat().st_size
            expanded += size
            if expanded > 2_147_483_648:
                raise ValueError("Unit exceeds expanded limit")
            role = "executable" if relative in EXECUTABLES or relative.endswith("/@esbuild/darwin-arm64/bin/esbuild") or relative.endswith("/bin/node") or relative.endswith("/fsevents/fsevents.node") else "resource"
            item = {"path": relative, "sha256": digest(path), "bytes": size, "role": role}
            if role == "executable":
                identifier = EXECUTABLES.get(relative)
                if identifier is None:
                    if relative.endswith("/bin/node"):
                        identifier = EXECUTABLES["bin/node"]
                    elif relative.endswith("/bin/esbuild"):
                        identifier = EXECUTABLES["node_modules/@esbuild/darwin-arm64/bin/esbuild"]
                    elif relative.endswith("/fsevents/fsevents.node"):
                        identifier = EXECUTABLES["node_modules/fsevents/fsevents.node"]
                    else:
                        raise ValueError(f"Unrecognized executable: {relative}")
                item["publisher"] = {"teamIdentifier": TEAM, "signingIdentifier": identifier}
            inventory.append(item)
            info = tarfile.TarInfo(relative)
            info.size = size
            info.mode = 0o500 if role == "executable" else 0o400
            info.uid = info.gid = 0
            info.uname = info.gname = ""
            info.mtime = 0
            with open(path, "rb") as stream:
                try:
                    archive.addfile(info, stream)
                except ValueError as error:
                    raise ValueError(f"Cannot encode USTAR member {relative!r}") from error
    if not set(EXECUTABLES).issubset({item["path"] for item in inventory}):
        raise ValueError("Missing required executable")
    archive_size = tar_path.stat().st_size
    if archive_size > 1_073_741_824:
        raise ValueError("Archive exceeds catalog limit")
    inventory_hash = hashlib.sha256(b"screenpunk/inventory/v1\0" + typed(inventory)).hexdigest()
    payload = {"catalogVersion": 1, "catalogId": "screenpunk-cli-offline-1.0.0",
               "channel": "stable", "sequence": 1, "entries": [{
                   "catalogEntryId": ENTRY, "kind": "authoringKit", "version": "1.0.0",
                   "platform": "darwin-arm64", "artifactSha256": digest(tar_path),
                   "artifactBytes": archive_size, "downloadURL": "",
                   "embeddedArtifactPath": "Resources/Toolchains/" + tar_path.name,
                   "publisher": {"teamIdentifier": TEAM, "signingIdentifier": "xyz.screenpunk.build-host"},
                   "inventoryHash": inventory_hash, "inventory": inventory}]}
    message = b"screenpunk/release-catalog/v1\0" + typed(payload)
    with tempfile.NamedTemporaryFile(prefix="screenpunk-catalog-sign-", delete=False) as stream:
        temp_path = pathlib.Path(stream.name)
        stream.write(message)
    try:
        signature = subprocess.check_output([str(signer), str(private_key), str(temp_path)], text=True).strip()
    finally:
        temp_path.unlink()
    if len(base64.b64decode(signature, validate=True)) != 64:
        raise ValueError("Invalid Ed25519 signature")
    envelope = {"signatureVersion": 1, "algorithm": "Ed25519", "signerKeyId": KEY_ID,
                "signatureBase64": signature, "payload": payload}
    envelope_path.write_text(json.dumps(envelope, separators=(",", ":"), ensure_ascii=False), encoding="utf-8")
    print(f"Catalog: {len(inventory)} files, {archive_size} archive bytes, inventory {inventory_hash}")


if __name__ == "__main__":
    main()
