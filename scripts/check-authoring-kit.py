"""Build a fresh project with the bundled runtime, no system Node/cache/network."""
import json, os, pathlib, shutil, subprocess, sys, tempfile
kit = pathlib.Path(sys.argv[1]).resolve()
required = ['bin/node', 'kit.json', 'catalog.json', 'THIRD-PARTY-NOTICES.txt', 'NODE-LICENSE.txt']
for name in required:
    if not (kit / name).is_file():
        raise SystemExit(f'Missing authoring asset: {name}')
with tempfile.TemporaryDirectory(prefix='screenpunk-offline-authoring-') as temp:
    root = pathlib.Path(temp)
    source = root / 'source'
    shutil.copytree(kit / 'templates/gallery', source)
    output = root / 'output'
    command = [str(kit / 'bin/node'), '--jitless', str(kit / 'scripts/build.mjs'), str(source), str(output)]
    if sys.platform == 'darwin':
        command = ['/usr/bin/sandbox-exec', '-p', '(version 1)(allow default)(deny network*)'] + command
    result = subprocess.run(command, env={'PATH': str(kit / 'bin'), 'HOME': str(root), 'TMPDIR': str(root)}, capture_output=True, text=True, timeout=120)
    if result.returncode:
        raise SystemExit(result.stderr)
    if not (output / 'screen.js').is_file() or not (output / 'THIRD-PARTY-NOTICES.txt').is_file():
        raise SystemExit('Bundled build did not emit a complete package')
    print('Offline bundled build passed:', result.stdout.strip())
