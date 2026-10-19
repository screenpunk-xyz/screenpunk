#!/usr/bin/env python3
"""Bounded, synthetic host/XPC/compiler probe. Takes an already signed fixture app."""
import base64
import hashlib
import json
import pathlib
import select
import struct
import subprocess
import sys

app = pathlib.Path(sys.argv[1])
templates = pathlib.Path(sys.argv[2])
exe = app / "Contents/MacOS/ScreenpunkBuildHost"


def exchange(process, message):
    body = json.dumps(message, separators=(",", ":")).encode()
    assert 0 < len(body) <= 512 * 1024
    process.stdin.write(struct.pack(">I", len(body)) + body)
    process.stdin.flush()
    assert select.select([process.stdout], [], [], 15)[0], f"host timeout on {message['action']}"
    header = process.stdout.read(4)
    assert len(header) == 4, f"host exited before reply: {process.poll()}"
    size = struct.unpack(">I", header)[0]
    assert 0 < size <= 3 * 1024 * 1024
    frame = json.loads(process.stdout.read(size))
    assert frame["id"] == message["id"], frame
    return base64.b64decode(frame["payload"])


for index, starter in enumerate(("earthquakes", "gallery")):
    process = subprocess.Popen([str(exe)], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                               stderr=subprocess.PIPE, env={"PATH": "/usr/bin:/bin"})
    try:
        job = f"fixture-{index}"
        next_id = 1

        def request(action, **fields):
            global next_id
            message = {"version": 1, "id": next_id, "action": action, "jobID": job, **fields}
            next_id += 1
            return exchange(process, message)

        reply = json.loads(request("prepare", projectID=starter, sourceVersion="a" * 64))
        assert reply["code"] == "ok", reply
        for file in sorted((templates / starter / "src").rglob("*")):
            if not file.is_file():
                continue
            relative = file.relative_to(templates / starter).as_posix()
            data = file.read_bytes()
            for offset in range(0, max(1, len(data)), 256 * 1024):
                chunk = data[offset:offset + 256 * 1024]
                final = hashlib.sha256(data).hexdigest() if offset + len(chunk) == len(data) else None
                reply = json.loads(request("upload", path=relative, offset=offset,
                    bytes=base64.b64encode(chunk).decode(), finalSHA256=final))
                assert reply["code"] == "ok", (relative, reply)
        result = json.loads(request("execute"))
        assert result["code"] == "ok", result
        if "SCREENPUNK_EXPECT_READ_PROBE" in __import__("os").environ:
            marker = "SCREENPUNK_READ_PROBE="
            line = next(line for line in result["diagnostics"].splitlines() if line.startswith(marker))
            probe = json.loads(line[len(marker):])
            assert probe["reads"] > 0 and probe["outsideReads"] == [] and probe["networkCalls"] == 0, probe
        files = result["files"]
        assert {"index.html", "screen.js", "screen.css", "THIRD-PARTY-NOTICES.txt"}.issubset(
            {entry["path"] for entry in files})
        for item in files:
            offset = 0
            digest = hashlib.sha256()
            while offset < item["bytes"]:
                packet = request("download", path=item["path"], offset=offset)
                assert packet[0] == 1 and len(packet) > 1
                chunk = packet[1:]
                digest.update(chunk)
                offset += len(chunk)
            assert offset == item["bytes"] and digest.hexdigest() == item["sha256"], item
        reply = json.loads(request("release"))
        assert reply["code"] == "ok", reply
        print(f"{starter}: {len(files)} verified files; host/XPC/compiler complete")
    finally:
        process.stdin.close()
        process.wait(timeout=5)
        diagnostics = process.stderr.read().decode(errors="replace")
        if diagnostics:
            print(diagnostics, file=sys.stderr)
        assert process.returncode == 0, process.returncode

process = subprocess.Popen([str(exe)], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                           stderr=subprocess.PIPE, env={"PATH": "/usr/bin:/bin"})
try:
    job = "outside-import"
    source = b"import '/etc/hosts';\nexport {};\n"
    digest = hashlib.sha256(source).hexdigest()
    prepared = json.loads(exchange(process, {"version": 1, "id": 1, "action": "prepare",
        "projectID": "outside-import", "jobID": job, "sourceVersion": "a" * 64}))
    assert prepared["code"] == "ok", prepared
    uploaded = json.loads(exchange(process, {"version": 1, "id": 2, "action": "upload",
        "jobID": job, "path": "src/main.tsx", "offset": 0,
        "bytes": base64.b64encode(source).decode(), "finalSHA256": digest}))
    assert uploaded["code"] == "ok", uploaded
    rejected = json.loads(exchange(process, {"version": 1, "id": 3, "action": "execute", "jobID": job}))
    assert rejected["code"] != "ok" and not rejected.get("files"), rejected
    print("outside import: rejected without package output")
finally:
    process.stdin.close()
    process.wait(timeout=5)
    diagnostics = process.stderr.read().decode(errors="replace")
    if diagnostics:
        print(diagnostics, file=sys.stderr)
    assert process.returncode == 0, process.returncode
