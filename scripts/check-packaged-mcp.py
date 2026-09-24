"""Verify bundled MCP and preview with temporary state and no service-discovery tool calls."""
import base64
import json
import os
import pathlib
import select
import subprocess
import sys
import tempfile
import time

if len(sys.argv) != 2:
    raise SystemExit("Usage: python3 scripts/check-packaged-mcp.py /path/to/Screenpunk.app")
app = pathlib.Path(sys.argv[1]).resolve()
exe = app / "Contents/MacOS/screenpunk-mcp"
helper = app / "Contents/Helpers/ScreenpunkPreviewHost.app/Contents/MacOS/ScreenpunkPreviewHost"
for binary in (exe, helper):
    if not binary.is_file() or not os.access(binary, os.X_OK):
        raise SystemExit(f"Required packaged executable missing or not executable: {binary}")
    if not binary.resolve().is_relative_to(app):
        raise SystemExit(f"Packaged executable resolves outside the candidate app: {binary}")

with tempfile.TemporaryDirectory(prefix="screenpunk-packaged-mcp-") as temporary:
    root = pathlib.Path(temporary)
    env = dict(os.environ)
    env.pop("SCREENPUNK_MCP_TRANSPORT", None)
    env.update(SCREENPUNK_CONTROLLER_HOME=str(root / "controller"),
               SCREENPUNK_PREVIEW_HOST=str(helper),
               SCREENPUNK_AGENT_NAME="Build Verification")
    with (root / "stderr.log").open("wb") as log:
        p = subprocess.Popen([str(exe)], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                             stderr=log, env=env, bufsize=0)
        buffered = bytearray()

        def send(data):
            p.stdin.write((json.dumps(data) + "\n").encode())
            p.stdin.flush()

        def response(request_id, timeout=45):
            deadline = time.monotonic() + timeout
            while time.monotonic() < deadline:
                while b"\n" in buffered:
                    line, _, rest = buffered.partition(b"\n")
                    buffered[:] = rest
                    value = json.loads(line)
                    if value.get("id") == request_id:
                        if value.get("error"):
                            raise RuntimeError(f"MCP request {request_id} failed")
                        return value["result"]
                if select.select([p.stdout], [], [], max(0, deadline - time.monotonic()))[0]:
                    chunk = os.read(p.stdout.fileno(), 65536)
                    if not chunk:
                        raise RuntimeError(f"MCP exited before response {request_id}")
                    buffered.extend(chunk)
                    if len(buffered) > 32 * 1024 * 1024:
                        raise RuntimeError("MCP response exceeds smoke-test output limit")
            raise TimeoutError(f"MCP response {request_id} timed out")

        def call(request_id, name, arguments):
            send({"jsonrpc": "2.0", "id": request_id, "method": "tools/call",
                  "params": {"name": name, "arguments": arguments}})
            result = response(request_id)
            if result.get("isError"):
                raise RuntimeError(f"MCP tool {name} failed")
            return result

        try:
            send({"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {
                "protocolVersion": "2024-11-05", "capabilities": {},
                "clientInfo": {"name": "Build Verification", "version": "1"}}})
            response(1)
            print("initialize: passed", flush=True)
            send({"jsonrpc": "2.0", "method": "notifications/initialized"})
            send({"jsonrpc": "2.0", "id": 2, "method": "tools/list", "params": {}})
            names = {tool["name"] for tool in response(2)["tools"]}
            if not {"update_dashboard", "preview_dashboard"}.issubset(names):
                raise RuntimeError("Packaged MCP lacks required authoring/preview tools")
            print(f"tools: {len(names)}", flush=True)
            created = call(3, "update_dashboard", {"name": "Smoke Clock", "files": [
                {"path": "index.html", "text": '<!doctype html><html><body><h1>Native build verified</h1><script src="ready.js"></script></body></html>'},
                {"path": "ready.js", "text": "window.screenpunk.runtime.ready();"},
            ]})
            payload = json.loads(created["content"][0]["text"])
            dashboard = payload.get("dashboardId") or payload.get("dashboard", {}).get("dashboardId")
            if not dashboard:
                raise RuntimeError("MCP did not return the temporary dashboard ID")
            preview = call(4, "preview_dashboard", {"dashboardId": dashboard})
            images = [item for item in preview["content"] if item.get("type") == "image"]
            if not images:
                raise RuntimeError("Packaged preview returned no image")
            data = base64.b64decode(images[0]["data"], validate=True)
            if not data.startswith(b"\x89PNG\r\n\x1a\n"):
                raise RuntimeError("Packaged preview did not return a PNG")
            (root / "preview.png").write_bytes(data)
            print(f"preview: PNG ({len(data)} bytes); packaged MCP check passed", flush=True)
            project = json.loads(call(5, "create_screen_project", {"starter": "gallery"})["content"][0]["text"])
            built = json.loads(call(6, "build_screen_project", {"projectId": project["projectId"], "sourceVersion": project["sourceVersion"]})["content"][0]["text"])
            call(7, "validate_dashboard", {"dashboardId": built["dashboardId"], "revision": built["revision"]})
            react_preview = call(8, "preview_dashboard", {"dashboardId": built["dashboardId"], "revision": built["revision"], "live": False})
            if not any(item.get("type") == "image" for item in react_preview["content"]):
                raise RuntimeError("React package did not produce a native preview")
            print("React create/build/validate/preview: passed", flush=True)
        finally:
            p.stdin.close()
            try:
                p.wait(timeout=5)
            except subprocess.TimeoutExpired:
                p.terminate()
                try:
                    p.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    p.kill()
                    p.wait()
            p.stdout.close()
