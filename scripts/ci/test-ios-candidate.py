#!/usr/bin/env python3
import sys
sys.dont_write_bytecode = True
import importlib.util
import pathlib
import unittest
import base64
import hashlib
import os
import plistlib
import subprocess
import tempfile
import zipfile

root = pathlib.Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('candidate', root / '.github/workflows/scripts/validate-ios-candidate.py')
policy = importlib.util.module_from_spec(spec); spec.loader.exec_module(policy)

class InternalCandidateTests(unittest.TestCase):
    def original(self):
        return {'ScreenpunkCloudAPIOrigin': 'https://staging.screenpunk.xyz',
                'ScreenpunkCloudFirebaseProjectID': 'screenpunk-stg-6f6e615a',
                'ScreenpunkCloudBundleID': 'xyz.screenpunk.ios'}

    def test_explicit_false_default_and_bad_input(self):
        self.assertFalse(policy.candidate_input({}))
        self.assertFalse(policy.candidate_input({'IOS_INTERNAL_CONCURRENT_CANDIDATE': 'false'}))
        self.assertTrue(policy.candidate_input({'IOS_INTERNAL_CONCURRENT_CANDIDATE': 'true'}))
        for value in ['1', 'TRUE', '', True, 'true\n']:
            with self.assertRaises(ValueError): policy.candidate_input({'IOS_INTERNAL_CONCURRENT_CANDIDATE': value})

    def test_derived_marker_does_not_change_original(self):
        original = self.original(); actual = policy.derived_info(original, True)
        self.assertNotIn(policy.MARKER, original)
        self.assertEqual(actual[policy.MARKER], policy.VALUE)
        policy.validate_candidate(actual, True)
        ordinary = policy.derived_info(original, False)
        self.assertNotIn(policy.MARKER, ordinary)
        policy.validate_candidate(ordinary, False)
        with self.assertRaises(ValueError): policy.validate_candidate(actual, False)
        with self.assertRaises(ValueError): policy.derived_info(actual, True)

    def test_stage_only_and_artifact_fail_closed(self):
        valid = policy.derived_info(self.original(), True)
        for key, wrong in [(policy.MARKER, ''), (policy.MARKER, True), (policy.MODE, 'ordinary'), (policy.COMPILE_FLAG, 'disabled'),
                           ('ScreenpunkCloudAPIOrigin', 'https://screenpunk.xyz'),
                           ('ScreenpunkCloudFirebaseProjectID', 'screenpunk-prod-2c99c8b7'),
                           ('ScreenpunkCloudBundleID', 'other')]:
            with self.assertRaises(ValueError): policy.validate_candidate(dict(valid, **{key: wrong}), True)
        for key in [policy.MARKER, policy.MODE, policy.COMPILE_FLAG, 'ScreenpunkCloudAPIOrigin', 'ScreenpunkCloudFirebaseProjectID']:
            broken = dict(valid); del broken[key]
            with self.assertRaises(ValueError): policy.validate_candidate(broken, True)
        with self.assertRaises(ValueError): policy.derived_info(dict(self.original(), ScreenpunkCloudAPIOrigin='https://production.invalid'), True)

    def test_actual_archive_validator_accepts_candidate_and_rejects_tampering(self):
        spec = importlib.util.spec_from_file_location('generator', root / 'scripts/generate-ios-staging-config.py')
        generator = importlib.util.module_from_spec(spec); spec.loader.exec_module(generator)
        template = plistlib.loads((root / 'apps/ios/Info.plist').read_bytes())
        firebase = {'PROJECT_ID': 'screenpunk-stg-6f6e615a', 'API_KEY': 'fixture-key', 'GOOGLE_APP_ID': '1:123:ios:fixture',
                    'GCM_SENDER_ID': '123', 'CLIENT_ID': 'fixture.apps.googleusercontent.com',
                    'REVERSED_CLIENT_ID': 'com.googleusercontent.apps.fixture', 'BUNDLE_ID': 'xyz.screenpunk.ios',
                    'IS_ANALYTICS_ENABLED': False}
        original = generator.build_info(firebase, template, expected_project='screenpunk-stg-6f6e615a',
                                        expected_bundle='xyz.screenpunk.ios', api_origin='https://staging.screenpunk.xyz')
        raw = plistlib.dumps(original)
        script = (root / '.github/workflows/scripts/ios-archive-export.sh').read_text().split("<<'PY_STAGING'\n", 1)[1].split('\nPY_STAGING', 1)[0]
        env = dict(os.environ, IOS_STAGING_INFO_PLIST_BASE64=base64.b64encode(raw).decode(),
                   IOS_STAGING_INFO_SHA256=hashlib.sha256(raw).hexdigest(), IOS_INTERNAL_CONCURRENT_CANDIDATE='true',
                   IOS_MARKETING_VERSION='1.0', IOS_BUILD_NUMBER='2')
        with tempfile.TemporaryDirectory() as work:
            def run(mode, artifact='', settings=env):
                return subprocess.run([sys.executable, '-c', script, mode, str(root), work, artifact], env=settings,
                                      capture_output=True, text=True).returncode
            self.assertEqual(run('prepare'), 0)
            info = plistlib.loads((pathlib.Path(work) / 'Info-staging.plist').read_bytes())
            self.assertEqual(info[policy.MARKER], policy.VALUE)
            info.update(CFBundleIdentifier='xyz.screenpunk.ios', CFBundleShortVersionString='1.0', CFBundleVersion='2',
                        MinimumOSVersion='16.0', UIDeviceFamily=[1, 2], ScreenpunkGoogleCalendarClientID='')
            for url in info['CFBundleURLTypes']:
                if url.get('CFBundleURLName') == 'Google Calendar OAuth': url['CFBundleURLSchemes'] = ['']
            archive = pathlib.Path(work) / 'archive/Products/Applications/Screenpunk.app'
            archive.mkdir(parents=True)
            archive_info = archive / 'Info.plist'
            archive_info.write_bytes(plistlib.dumps(info))
            self.assertEqual(run('archive', str(pathlib.Path(work) / 'archive')), 0)
            ipa = pathlib.Path(work) / 'candidate.ipa'
            with zipfile.ZipFile(ipa, 'w') as output: output.writestr('Payload/Screenpunk.app/Info.plist', plistlib.dumps(info))
            self.assertEqual(run('ipa', str(ipa)), 0)
            self.assertNotEqual(run('archive', str(pathlib.Path(work) / 'archive'), dict(env, IOS_INTERNAL_CONCURRENT_CANDIDATE='false')), 0)
            for key, value in [(policy.MARKER, 'wrong'), (policy.COMPILE_FLAG, 'disabled'),
                               ('ScreenpunkCloudFirebaseProjectID', 'screenpunk-prod-2c99c8b7')]:
                broken = dict(info, **{key: value}); archive_info.write_bytes(plistlib.dumps(broken))
                self.assertNotEqual(run('archive', str(pathlib.Path(work) / 'archive')), 0)
            self.assertNotEqual(run('prepare', settings=dict(env, IOS_STAGING_INFO_SHA256='0'*64)), 0)

    def test_archive_wires_candidate_after_protected_validation(self):
        script = (root / '.github/workflows/scripts/ios-archive-export.sh').read_text()
        self.assertLess(script.index('if supplied != expected:'), script.index('policy.derived_info(expected, candidate)'))
        self.assertIn('policy.validate_candidate(actual, candidate)', script)
        self.assertIn('SWIFT_ACTIVE_COMPILATION_CONDITIONS="$candidate_flags"', script)
        self.assertIn(policy.FLAG, script)
        self.assertIn('Add :testFlightInternalTestingOnly bool true', script)

if __name__ == '__main__': unittest.main()
