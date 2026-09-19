import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
const root = fileURLToPath(new URL('../../', import.meta.url));

function select(host, xcode = '26.6') {
  return spawnSync('bash', ['-c', `
    set -euo pipefail
    sw_vers() { echo "$TEST_HOST_VERSION"; }
    xcodebuild() { echo "Xcode $TEST_XCODE_VERSION"; }
    export DEVELOPER_DIR=/test/Xcode.app/Contents/Developer
    source scripts/select-icon-xcode.sh
    echo "selected=$DEVELOPER_DIR"
  `], { cwd: root, encoding: 'utf8', env: { ...process.env, TEST_HOST_VERSION: host, TEST_XCODE_VERSION: xcode } });
}

test('rejects the crashing macOS 15 + Xcode 26 combination before building', () => {
  const result = select('15.7.9', '26.0.1');
  assert.equal(result.status, 1);
  assert.match(result.stderr, /macOS 26\+ host/);
  assert.doesNotMatch(result.stdout, /selected=/);
});
test('accepts the validated Tahoe host without changing explicit Xcode selection', () => {
  const result = select('26.6');
  assert.equal(result.status, 0, result.stderr);
  assert.match(result.stdout, /selected=\/test\/Xcode.app\/Contents\/Developer/);
});
test('still rejects Xcode 16 on a compatible host', () => {
  const result = select('26.6', '16.4');
  assert.equal(result.status, 1);
  assert.match(result.stderr, /require Xcode 26\+/);
});
test('all app build and packaging jobs use a compatible host; preview keeps older-host coverage', () => {
  for (const [file, jobs] of Object.entries({
    'ci.yml': ['apple-build-and-unit'],
    'ios-testflight.yml': ['apple-precheck', 'ios-sign-export'],
    'macos-release.yml': ['apple-precheck', 'macos-sign-notarize'],
    'macos-unsigned-dmg.yml': ['macos-unsigned-dmg'],
  })) {
    const workflow = readFileSync(`${root}.github/workflows/${file}`, 'utf8');
    for (const job of jobs) {
      const block = workflow.split(`\n  ${job}:\n`)[1]?.split(/\n  [a-z][\w-]*:\n/)[0];
      assert.ok(block, `${file}: missing ${job}`);
      assert.match(block, /runs-on: macos-26\b/, `${file}: ${job}`);
    }
  }
  const ci = readFileSync(`${root}.github/workflows/ci.yml`, 'utf8');
  assert.match(ci, /apple-ui-and-preview:\n[^]*?runs-on: macos-15\b/);
});
