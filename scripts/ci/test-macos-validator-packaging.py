#!/usr/bin/env python3
"""Exercise the real release orchestration offline; every signing/build tool is a stub."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


class MacValidatorPackagingTests(unittest.TestCase):
    def run_packaging(self, fail=False):
        with tempfile.TemporaryDirectory(prefix="screenpunk-packaging-") as temporary:
            root = Path(temporary)
            def write(path, body):
                target = root / path
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_text(body)
                target.chmod(0o755)
            script = ".github/workflows/scripts/macos-archive-notarize.sh"
            write(script, (ROOT / script).read_text())
            write(".github/workflows/scripts/apple-signing-common.sh", '''
ROOT="$FIXTURE_ROOT"
RELEASE_DIR="$ROOT/release"
WORK_DIR="$ROOT/work"
SIGNING_IDENTITY_SHA1=offline-stub
APPLE_TEAM_ID=offline-stub
mkdir -p "$RELEASE_DIR" "$WORK_DIR"
require_apple_team_id() { :; }
require_macos_26_sdk() { :; }
import_p12() { :; }
''')
            write("scripts/select-icon-xcode.sh", ":\n")
            write("scripts/generate-xcode.sh", "#!/bin/bash\nexit 0\n")
            write("scripts/bundle-authoring.sh", "#!/bin/bash\nmkdir -p \"$1/Contents/Resources/AuthoringKit\"\n")
            write("scripts/bundle-connection-validator.sh", '''#!/bin/bash
set -eu
test ! -d "$1"
if [[ "$FAIL_BUNDLE" == 1 ]]; then exit 42; fi
mkdir -p "$1"
for member in node validate.cjs SBOM.json inventory.json NODE-LICENSE.txt THIRD-PARTY-NOTICES.txt; do
  echo fixture > "$1/$member"
done
''')
            write("bin/xcodebuild", '''#!/bin/bash
mkdir -p "$FIXTURE_ROOT/release/macos-export/Screenpunk.app/Contents/MacOS"
''')
            write("bin/swift", '#!/bin/bash\necho "$FIXTURE_ROOT/swift-output"\n')
            write("bin/ditto", '#!/bin/bash\nmkdir -p "$(dirname "$2")"\n')
            write("bin/file", '''#!/bin/bash
for member in "$@"; do
 [[ "$member" == */ConnectionValidator/node ]] && echo "$member: Mach-O executable"
done
exit 0
''')
            write("bin/codesign", '''#!/bin/bash
set -eu
printf '%s\n' "$*" >> "$FIXTURE_ROOT/signing-calls"
app="$FIXTURE_ROOT/release/macos-export/Screenpunk.app"
for member in node validate.cjs SBOM.json inventory.json NODE-LICENSE.txt THIRD-PARTY-NOTICES.txt; do
 test -f "$app/Contents/Resources/ConnectionValidator/$member"
done
if [[ "${!#}" == "$app" ]]; then exit 75; fi
''')
            # Any accidental advance to packaging/notarization fails the test.
            for command in ["xcrun", "hdiutil", "security", "spctl"]:
                write("bin/" + command, "#!/bin/bash\nexit 99\n")
            result = subprocess.run(["bash", str(root / script)], cwd=root,
                env={**os.environ, "PATH": str(root / "bin") + ":/usr/bin:/bin",
                     "FIXTURE_ROOT": str(root), "FAIL_BUNDLE": str(int(fail))},
                text=True, capture_output=True)
            calls = (root / "signing-calls").read_text() if (root / "signing-calls").exists() else ""
            return result, calls

    def test_fresh_release_job_builds_helper_before_nested_and_app_signing(self):
        result, calls = self.run_packaging()
        self.assertEqual(result.returncode, 75, result.stdout + result.stderr)
        self.assertIn("--identifier xyz.screenpunk.connection-validator.node", calls)
        self.assertLess(calls.index("ConnectionValidator/node"), calls.index("Helpers/ScreenpunkPreviewHost.app"))

    def test_helper_packaging_failure_stops_before_signing(self):
        result, calls = self.run_packaging(fail=True)
        self.assertEqual(result.returncode, 42, result.stdout + result.stderr)
        self.assertEqual(calls, "")


if __name__ == "__main__":
    unittest.main()
