#!/usr/bin/env python3
"""Check the distribution-sensitive contents of an archived/built store app."""
import argparse
import plistlib
import subprocess
from pathlib import Path

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('product', choices=['sync', 'stream'])
parser.add_argument('app', type=Path)
args = parser.parse_args()
contents = args.app / 'Contents' if args.product == 'sync' else args.app
with (contents / 'Info.plist').open('rb') as source:
    info = plistlib.load(source)
expected = 'com.mesutcy.remotedesktop.' + ('minhost' if args.product == 'sync' else 'stream')
assert info['CFBundleIdentifier'] == expected, 'Wrong app identity'
assert info['CFBundleDisplayName'] == ('App Sync' if args.product == 'sync' else 'App Stream'), 'Wrong store display name'
assert info['VampDistributionChannel'] == 'app-store', 'Website distribution accidentally archived'
assert all(info.get(key) for key in ['CFBundleShortVersionString', 'CFBundleVersion']), 'Missing version'
resources = contents / 'Resources' if args.product == 'sync' else contents
assert (resources / 'PrivacyInfo.xcprivacy').is_file(), 'Missing privacy manifest'
updater_components = {'Sparkle.framework', 'Autoupdate', 'Updater.app',
                      'org.sparkle-project.Downloader.xpc', 'org.sparkle-project.Installer.xpc'}
assert not any(path.name in updater_components for path in args.app.rglob('*')), 'External updater bundled'
assert not any(key.startswith('SU') for key in info), 'Sparkle configuration in store bundle'
assert (contents / ('MacOS' if args.product == 'sync' else '') / info['CFBundleExecutable']).is_file(), 'Missing executable'
if (contents / '_CodeSignature').exists():
    result = subprocess.run(['codesign', '-d', '--entitlements', ':-', str(args.app)], capture_output=True, check=True)
    entitlements = plistlib.loads(result.stdout)
    if args.product == 'sync':
        assert entitlements.get('com.apple.security.app-sandbox') is True, 'Sandbox disabled'
        assert entitlements.get('com.apple.security.network.client') is True, 'Missing client networking'
        assert entitlements.get('com.apple.security.network.server') is True, 'Missing server networking'
    assert not any('temporary-exception' in key for key in entitlements), 'Sandbox exception in store build'
    assert not entitlements.get('com.apple.developer.networking.multicast'), 'Unexpected multicast entitlement'
    print('Verified signed store bundle:', args.app)
else:
    print('Verified unsigned store bundle contents (signing not checked):', args.app)
