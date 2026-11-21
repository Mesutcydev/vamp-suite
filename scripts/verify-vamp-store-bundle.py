#!/usr/bin/env python3
"""Check the distribution-sensitive contents of an archived/built store app."""
import argparse
from datetime import datetime, timezone
from fnmatch import fnmatchcase
import plistlib
import subprocess
import tempfile
from pathlib import Path

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('product', choices=['sync', 'stream', 'control', 'control-ios'])
parser.add_argument('app', type=Path)
parser.add_argument('--require-distribution-profile', action='store_true',
                    help='Validate the embedded App Store profile and signing identity before delivery/TestFlight.')
args = parser.parse_args()
is_mac = args.product in ('sync', 'control')
contents = args.app / 'Contents' if is_mac else args.app
with (contents / 'Info.plist').open('rb') as source:
    info = plistlib.load(source)
expected = 'com.mesutcy.remotedesktop.' + {
    'sync': 'host', 'stream': 'stream', 'control': 'macclient', 'control-ios': 'ios'
}[args.product]
assert info['CFBundleIdentifier'] == expected, 'Wrong app identity'
assert info['CFBundleDisplayName'] == {
    'sync': 'Vamp Sync', 'stream': 'App Stream', 'control': 'Vamp Control', 'control-ios': 'Vamp Control'
}[args.product], 'Wrong store display name'
assert info['VampDistributionChannel'] == 'app-store', 'Website distribution accidentally archived'
assert all(info.get(key) for key in ['CFBundleShortVersionString', 'CFBundleVersion']), 'Missing version'
resources = contents / 'Resources' if is_mac else contents
assert (resources / 'PrivacyInfo.xcprivacy').is_file(), 'Missing privacy manifest'
updater_components = {'Sparkle.framework', 'Autoupdate', 'Updater.app',
                      'org.sparkle-project.Downloader.xpc', 'org.sparkle-project.Installer.xpc'}
assert not any(path.name in updater_components for path in args.app.rglob('*')), 'External updater bundled'
assert not any(key.startswith('SU') for key in info), 'Sparkle configuration in store bundle'
assert (contents / ('MacOS' if is_mac else '') / info['CFBundleExecutable']).is_file(), 'Missing executable'
if args.product == 'sync':
    # Scan every bundled Mach-O, including static package code linked into the
    # executable. App target compilation flags do not propagate to Swift packages.
    forbidden_lock_dependencies = (b'CGSSessionScreenIsLocked', b'com.apple.screenIsLocked', b'com.apple.screenIsUnlocked')
    macho_magic = {bytes.fromhex(value) for value in ('feedface', 'feedfacf', 'cefaedfe', 'cffaedfe', 'cafebabe', 'bebafeca', 'cafebabf', 'bfbafeca')}
    for path in args.app.rglob('*'):
        if not path.is_file():
            continue
        with path.open('rb') as binary:
            if binary.read(4) not in macho_magic:
                continue
            binary.seek(0)
            data = binary.read()
        assert not any(value in data for value in forbidden_lock_dependencies), f'Undocumented lock dependency in Store binary: {path}'
if (contents / '_CodeSignature').exists():
    subprocess.run(['codesign', '--verify', '--deep', '--strict', str(args.app)], check=True)
    result = subprocess.run(['codesign', '-d', '--entitlements', '-', '--xml', str(args.app)], capture_output=True, check=True)
    entitlements = plistlib.loads(result.stdout)
    if is_mac:
        assert entitlements.get('com.apple.security.app-sandbox') is True, 'Sandbox disabled'
        assert entitlements.get('com.apple.security.network.client') is True, 'Missing client networking'
    if args.product == 'sync':
        assert entitlements.get('com.apple.security.network.server') is True, 'Missing server networking'
    if args.product == 'control':
        assert entitlements.get('com.apple.security.files.user-selected.read-write') is True, 'Missing user-selected file access'
    assert not any('temporary-exception' in key for key in entitlements), 'Sandbox exception in store build'
    assert not entitlements.get('com.apple.developer.networking.multicast'), 'Unexpected multicast entitlement'
    if args.require_distribution_profile:
        profile_path = contents / ('embedded.provisionprofile' if is_mac else 'embedded.mobileprovision')
        assert profile_path.is_file(), 'Missing embedded provisioning profile: not eligible for TestFlight'
        decoded = subprocess.run(['security', 'cms', '-D', '-i', str(profile_path)], capture_output=True, check=True)
        profile = plistlib.loads(decoded.stdout)
        assert profile['ExpirationDate'].replace(tzinfo=timezone.utc) > datetime.now(timezone.utc), 'Expired provisioning profile'
        assert not profile.get('ProvisionedDevices'), 'Development/ad hoc profile used for Store delivery'
        assert not profile.get('ProvisionsAllDevices'), 'Enterprise/Developer ID profile used for Store delivery'
        assert ('OSX' if is_mac else 'iOS') in profile['Platform'], 'Wrong profile platform'
        profile_entitlements = profile['Entitlements']
        app_id_key = 'com.apple.application-identifier' if is_mac else 'application-identifier'
        app_id = entitlements.get(app_id_key)
        assert app_id in [prefix + '.' + expected for prefix in profile['ApplicationIdentifierPrefix']], 'Missing or mismatched signed application identifier'
        assert fnmatchcase(app_id, profile_entitlements[app_id_key]), 'Profile does not authorize the app identifier'
        team = entitlements.get('com.apple.developer.team-identifier')
        assert team in profile['TeamIdentifier'], 'Missing or mismatched signed team identifier'
        assert team == profile_entitlements['com.apple.developer.team-identifier'], 'Profile team entitlement mismatch'
        for key in ('get-task-allow', 'com.apple.security.get-task-allow'):
            assert not entitlements.get(key) and not profile_entitlements.get(key), 'Debug entitlement in Store delivery'
        with tempfile.TemporaryDirectory(prefix='vamp-store-cert-') as directory:
            prefix = str(Path(directory) / 'certificate-')
            subprocess.run(['codesign', '-d', '--extract-certificates=' + prefix, str(args.app)], capture_output=True, check=True)
            certificate = Path(prefix + '0').read_bytes()
            assert certificate in profile['DeveloperCertificates'], 'Signing certificate is not authorized by the profile'
        print('Verified embedded distribution profile:', profile['UUID'])
    print('Verified signed store bundle:', args.app)
else:
    assert not args.require_distribution_profile, 'Unsigned app cannot be delivered to the Store/TestFlight'
    print('Verified unsigned store bundle contents (signing not checked):', args.app)
