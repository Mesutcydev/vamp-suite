#!/usr/bin/env python3
"""Export a Mac store app with an explicit profile mapping and verify its PKG payload."""
import argparse
from datetime import datetime, timezone
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tempfile

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--product', choices=['sync', 'control'], default='sync')
parser.add_argument('--archive', type=Path, required=True)
parser.add_argument('--profile', type=Path, required=True, help='Installed Mac App Store distribution profile file')
parser.add_argument('--team', required=True)
parser.add_argument('--signing-identity', default='Apple Distribution')
parser.add_argument('--installer-identity', required=True, help='Mac Installer Distribution certificate name or SHA-1')
parser.add_argument('--output', type=Path, required=True, help='New .pkg output path (never overwritten)')
args = parser.parse_args()
if args.output.exists():
    parser.error('Output already exists; use a new release path.')
if args.output.suffix != '.pkg':
    parser.error('Output must end in .pkg.')

bundle_id = 'com.mesutcy.remotedesktop.' + ('host' if args.product == 'sync' else 'macclient')
bundle_name = 'Vamp Sync.app' if args.product == 'sync' else 'Vamp Control.app'
app = args.archive / 'Products/Applications' / bundle_name
info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
assert info['CFBundleIdentifier'] == bundle_id, 'Wrong archive identity'
profile = plistlib.loads(subprocess.run(
    ['security', 'cms', '-D', '-i', str(args.profile)], capture_output=True, check=True
).stdout)
assert args.team in profile['TeamIdentifier'], 'Profile does not belong to the supplied team'
assert 'OSX' in profile['Platform'], 'Expected a macOS profile'
assert profile['ExpirationDate'].replace(tzinfo=timezone.utc) > datetime.now(timezone.utc), 'Expired profile'
assert not profile.get('ProvisionedDevices') and not profile.get('ProvisionsAllDevices'), 'Expected an App Store distribution profile'
assert profile['Entitlements']['com.apple.application-identifier'] in [
    prefix + '.' + bundle_id for prefix in profile['ApplicationIdentifierPrefix']
], 'Profile must explicitly identify this app'

args.output.parent.mkdir(parents=True, exist_ok=True)
options_path = args.output.with_suffix('.ExportOptions.plist')
options = {
    'method': 'app-store-connect',
    'destination': 'export',
    'signingStyle': 'manual',
    'teamID': args.team,
    'signingCertificate': args.signing_identity,
    'installerSigningCertificate': args.installer_identity,
    # Without this mapping Xcode can export a validly signed macOS package
    # without a profile, which Apple rejects for TestFlight (ITMS-90889).
    'provisioningProfiles': {bundle_id: profile['UUID']},
    'manageAppVersionAndBuildNumber': False,
}
options_path.write_bytes(plistlib.dumps(options))
with tempfile.TemporaryDirectory(prefix='.' + args.product + '-export-', dir=args.output.parent) as directory:
    temporary = Path(directory)
    export_path = temporary / 'export'
    subprocess.run([
        'xcodebuild', '-exportArchive', '-archivePath', str(args.archive),
        '-exportOptionsPlist', str(options_path), '-exportPath', str(export_path)
    ], check=True)
    packages = list(export_path.glob('*.pkg'))
    assert len(packages) == 1, 'Expected exactly one exported installer'
    subprocess.run(['pkgutil', '--check-signature', str(packages[0])], check=True)
    expanded = temporary / 'payload'
    subprocess.run(['pkgutil', '--expand-full', str(packages[0]), str(expanded)], check=True)
    apps = list(expanded.glob('**/Payload/' + bundle_name))
    assert len(apps) == 1, 'Expected exactly one app payload'
    subprocess.run([
        sys.executable, str(Path(__file__).with_name('verify-vamp-store-bundle.py')),
        args.product, str(apps[0]), '--require-distribution-profile'
    ], check=True)
    exported = plistlib.loads((apps[0] / 'Contents/Info.plist').read_bytes())
    for key in ('CFBundleIdentifier', 'CFBundleShortVersionString', 'CFBundleVersion'):
        assert exported[key] == info[key], f'Export changed {key}'
    shutil.move(str(packages[0]), str(args.output))
print('Verified Store/TestFlight package:', args.output)
