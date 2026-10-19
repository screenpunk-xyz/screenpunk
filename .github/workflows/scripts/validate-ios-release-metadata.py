#!/usr/bin/env python3
"""Validate explicit release inputs and exported universal IPA metadata, without signing."""
import os
import plistlib
import re
import sys
import zipfile


def release_inputs(environ):
    version = environ.get('IOS_MARKETING_VERSION', '')
    build = environ.get('IOS_BUILD_NUMBER', '')
    # Deliberately accept numeric release strings only; no prerelease suffixes.
    if not re.fullmatch(r'(?:0|[1-9][0-9]*)(?:\.(?:0|[1-9][0-9]*)){1,2}', version):
        raise ValueError('IOS_MARKETING_VERSION must contain two or three numeric components')
    # Integer-only build policy is narrower than Apple's three-component format.
    if not re.fullmatch(r'[1-9][0-9]{0,3}', build):
        raise ValueError('IOS_BUILD_NUMBER must be a positive integer of at most four digits')
    return version, build


def validate_ipa(path, version, build):
    with zipfile.ZipFile(path) as archive:
        names = [n for n in archive.namelist() if re.fullmatch(r'Payload/[^/]+\.app/Info\.plist', n)]
        if len(names) != 1:
            raise ValueError('IPA must contain exactly one main application Info.plist')
        info = plistlib.loads(archive.read(names[0]))
    if not isinstance(info, dict):
        raise ValueError('Main application Info.plist must be a dictionary')
    families = info.get('UIDeviceFamily')
    if type(families) is not list or any(type(value) is not int for value in families):
        raise ValueError('Exported IPA UIDeviceFamily must be a list of integers')
    expected = {'CFBundleIdentifier': 'xyz.screenpunk.ios',
                'CFBundleShortVersionString': version, 'CFBundleVersion': build,
                'MinimumOSVersion': '16.0', 'UIDeviceFamily': [1, 2]}
    for key, value in expected.items():
        if info.get(key) != value:
            raise ValueError('Exported IPA does not match required ' + key)


def main():
    try:
        version, build = release_inputs(os.environ)
        if sys.argv[1:] == ['inputs']:
            pass
        elif len(sys.argv) == 3 and sys.argv[1] == 'ipa':
            validate_ipa(sys.argv[2], version, build)
        else:
            raise ValueError('Usage: validate-ios-release-metadata.py inputs | ipa PATH')
    except (ValueError, OSError, zipfile.BadZipFile, plistlib.InvalidFileException) as error:
        print('iOS release validation failed: ' + str(error), file=sys.stderr)
        return 1
    print('iOS release metadata validated')
    return 0


if __name__ == '__main__':
    sys.exit(main())
