"""Verify feed-derived filenames render in the debug native preview, without network access."""
import json
import os
import pathlib
import subprocess
import sys
import tempfile

root = pathlib.Path(__file__).resolve().parent.parent
helper = pathlib.Path(sys.argv[1]).resolve()
package = root / 'examples/public-read-animation'
manifest = json.loads((package / 'manifest.json').read_text())
provisioning = {'publicReads': {'schemaVersion': 1, 'dashboardId': manifest['dashboardId'],
                              'revision': manifest['revision'], 'connections': manifest['connections']}}
with tempfile.TemporaryDirectory(prefix='screenpunk-dynamic-raster-') as temp:
    output = pathlib.Path(temp) / 'preview.png'
    env = dict(os.environ, SCREENPUNK_SNAPSHOT='1', SCREENPUNK_PUBLIC_READ_FIXTURE='1',
               SCREENPUNK_PREVIEW_LIVE='1', SCREENPUNK_PACKAGE_DIR=str(package),
               SCREENPUNK_VIEWPORT_WIDTH='640', SCREENPUNK_VIEWPORT_HEIGHT='640',
               SCREENPUNK_SNAPSHOT_OUT=str(output), SCREENPUNK_READY_TIMEOUT='25')
    result = subprocess.run([str(helper)], input=json.dumps(provisioning), env=env,
                            capture_output=True, text=True, timeout=35)
    if (result.returncode or 'DYNAMIC_RASTER_PROBE_OK' not in result.stderr or
            'SNAPSHOT_OK' not in result.stderr or not output.exists() or
            not output.read_bytes().startswith(b'\x89PNG\r\n\x1a\n')):
        raise SystemExit(result.stdout + result.stderr or 'Native dynamic raster preview failed')
    print('DYNAMIC_RASTER_PREVIEW_OK: two discovered filenames decoded into native handles; stale cache replay rendered')
