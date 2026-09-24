"""Run production gallery interactions through the debug native WKWebView helper."""
import json, os, pathlib, subprocess, sys, tempfile
root = pathlib.Path(__file__).resolve().parent.parent
helper = pathlib.Path(sys.argv[1]).resolve()
with tempfile.TemporaryDirectory(prefix='screenpunk-react-preview-') as temp:
    for width,height,appearance in [(1024,768,'light'),(768,1024,'dark')]:
        env = dict(os.environ, SCREENPUNK_SNAPSHOT='1', SCREENPUNK_AUTHORING_PROBE='1',
                   SCREENPUNK_PACKAGE_DIR=str(root/'authoring/dist/gallery'),
                   SCREENPUNK_VIEWPORT_WIDTH=str(width), SCREENPUNK_VIEWPORT_HEIGHT=str(height),
                   SCREENPUNK_AUTHORING_APPEARANCE=appearance,
                   SCREENPUNK_SNAPSHOT_OUT=str(pathlib.Path(temp)/f'{appearance}.png'))
        result = subprocess.run([str(helper)], env=env, capture_output=True, text=True, timeout=30)
        lines = [line for line in result.stderr.splitlines() if line.startswith('AUTHORING_PROBE ')]
        if result.returncode or not lines:
            raise SystemExit(result.stdout+result.stderr)
        report=json.loads(lines[-1].split(' ',1)[1])
        if report['failures'] or report['violations']:
            raise SystemExit(json.dumps(report))
        print(appearance, json.dumps(report))
