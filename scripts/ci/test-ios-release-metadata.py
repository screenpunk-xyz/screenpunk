#!/usr/bin/env python3
import sys
sys.dont_write_bytecode = True
import importlib.util
import pathlib
import plistlib
import tempfile
import unittest
import zipfile

root = pathlib.Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('metadata', root / '.github/workflows/scripts/validate-ios-release-metadata.py')
metadata = importlib.util.module_from_spec(spec)
spec.loader.exec_module(metadata)

class ReleaseMetadataTests(unittest.TestCase):
    def test_inputs(self):
        for version in ['1.0', '1.0.1', '0.1']:
            self.assertEqual(metadata.release_inputs({'IOS_MARKETING_VERSION': version, 'IOS_BUILD_NUMBER': '2'}), (version, '2'))
        for version in ['', '1', '1.0-beta', ' 1.0', '1.0\n', '1.0.0.0', '01.0', '$(touch x)']:
            with self.assertRaises(ValueError):
                metadata.release_inputs({'IOS_MARKETING_VERSION': version, 'IOS_BUILD_NUMBER': '2'})
        for build in ['', '0', '-1', '2.1', '02', '2\n', '10000', '${SECRET}']:
            with self.assertRaises(ValueError):
                metadata.release_inputs({'IOS_MARKETING_VERSION': '1.0', 'IOS_BUILD_NUMBER': build})

    def test_export(self):
        info = {'CFBundleIdentifier': 'xyz.screenpunk.ios', 'CFBundleShortVersionString': '1.0', 'CFBundleVersion': '2', 'MinimumOSVersion': '16.0', 'UIDeviceFamily': [1, 2]}
        with tempfile.TemporaryDirectory() as directory:
            path = pathlib.Path(directory) / 'fixture.ipa'
            def write(value, duplicate=False):
                with zipfile.ZipFile(path, 'w') as archive:
                    archive.writestr('Payload/Screenpunk.app/Info.plist', plistlib.dumps(value, fmt=plistlib.FMT_BINARY))
                    if duplicate: archive.writestr('Payload/Other.app/Info.plist', plistlib.dumps(value))
            write(info); metadata.validate_ipa(path, '1.0', '2')
            for key, wrong in [('CFBundleVersion', '1'), ('CFBundleShortVersionString', '1.1'), ('UIDeviceFamily', [1]), ('MinimumOSVersion', '17.0'), ('CFBundleIdentifier', 'other')]:
                write(dict(info, **{key: wrong}))
                with self.assertRaises(ValueError): metadata.validate_ipa(path, '1.0', '2')
            for wrong in [[True, 2], [1.0, 2.0], [1, False], '1,2']:
                write(dict(info, UIDeviceFamily=wrong))
                with self.assertRaises(ValueError): metadata.validate_ipa(path, '1.0', '2')
            for malformed in [[1, 2], "not a dictionary"]:
                write(malformed)
                with self.assertRaises(ValueError): metadata.validate_ipa(path, '1.0', '2')
            with zipfile.ZipFile(path, 'w') as archive:
                archive.writestr('Payload/Screenpunk.app/Info.plist', b'not a plist')
            with self.assertRaises(plistlib.InvalidFileException): metadata.validate_ipa(path, '1.0', '2')
            write(info, True)
            with self.assertRaises(ValueError): metadata.validate_ipa(path, '1.0', '2')

if __name__ == '__main__': unittest.main()
