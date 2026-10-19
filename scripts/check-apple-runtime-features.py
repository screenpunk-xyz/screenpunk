#!/usr/bin/env python3
"""Check the actual app executable(s), including Xcode debug dylibs, before install."""
import pathlib
import sys

app = pathlib.Path(sys.argv[1])
mac = app / 'Contents/MacOS/Screenpunk'
binary_dir = mac.parent if mac.exists() else app
executables = [binary_dir / 'Screenpunk', *binary_dir.glob('*.dylib')]
data = b''.join(p.read_bytes() for p in executables if p.is_file())
required = {
    'declarative device activation': b'DeviceTemporaryActivationRuntime',
    'durable screen preferences': b'ScreenPreferenceStore',
    'native Calendar connection': b'GoogleCalendarDeviceService',
    'native Maps': b'InteractiveMapController',
}
missing = [name for name, marker in required.items() if marker not in data]
if missing:
    raise SystemExit('App is missing required runtime features: ' + ', '.join(missing))
print('Combined Apple runtime verified: ' + ', '.join(required))
