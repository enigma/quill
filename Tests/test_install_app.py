"""Installer integration tests with simulated macOS/build tools; no Keychain writes."""
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tempfile
import unittest

REPO = Path(__file__).resolve().parents[1]
TOOLS = r'''#!/usr/bin/env python3
import json, os, pathlib, plistlib, sys
name = pathlib.Path(sys.argv[0]).name
args = sys.argv[1:]
with open(os.environ['CALLS'], 'a') as f:
    f.write(json.dumps([name, *args]) + '\n')
if name == 'pgrep':
    sys.exit(1)
elif name == 'xcrun':
    print(os.environ.get('SWIFT_RESOLUTION', str(pathlib.Path(sys.argv[0]).with_name('swift'))))
elif name == 'swift':
    if '--show-bin-path' in args: print(os.environ['BINARY_DIR'])
    elif os.environ.get('QUILL_BUNDLE_PLIST'):
        pathlib.Path(os.environ['CALLS'] + '.build-plist').write_bytes(
            pathlib.Path(os.environ['QUILL_BUNDLE_PLIST']).read_bytes())
elif name == 'security':
    if args[0] == 'find-identity' and os.environ.get('NO_KEY') != '1':
        print('  1) ' + 'A' * 40 + ' "QuillLocalDev" (CSSMERR_TP_NOT_TRUSTED)')
    elif args[0] == 'default-keychain': print('    "/fake/login.keychain-db"')
elif name == 'openssl':
    if args[0] == 'req':
        pathlib.Path(args[args.index('-keyout')+1]).write_text('test key')
        pathlib.Path(args[args.index('-out')+1]).write_text('test certificate')
    elif args[0] == 'pkcs12':
        pathlib.Path(args[args.index('-out')+1]).write_text('test identity')
    else: print('sha1 Fingerprint=' + ':'.join(['AA'] * 20))
elif name == 'codesign':
    if '--verify' in args and args[-1] == os.environ['QUILL_APP_PATH'] and os.environ.get('INVALID') == '1':
        sys.exit(1)
    if '-R' in args:
        requirement = args[args.index('-R') + 1]
        if not requirement.startswith('='):
            print('invalid requirement specification: expected inline text', file=sys.stderr)
            sys.exit(1)
        if os.environ.get('WRONG_KEY') == '1': sys.exit(1)
    if '-dv' in args: print('Authority=QuillLocalDev')
    if '-r-' in args: print('designated => identifier "test.quill" and certificate leaf = H"' + 'a' * 40 + '"')
elif name == 'PlistBuddy':
    command, file = args[1], pathlib.Path(args[2])
    with file.open('rb') as f: data = plistlib.load(f)
    words = command.split()
    key = words[1].lstrip(':')
    if words[0] == 'Print': print(data[key])
    else:
        value = ' '.join(words[3:] if words[0] == 'Add' else words[2:])
        data[key] = (value == 'true') if words[0] == 'Add' and words[2] == 'bool' else value
        with file.open('wb') as f: plistlib.dump(data, f)
'''


class InstallerTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        (self.root / 'scripts').mkdir()
        script = (REPO / 'scripts/install-app.sh').read_text()
        (self.root / 'Sources/quill').mkdir(parents=True)
        shutil.copy(REPO / 'Sources/quill/Info.plist', self.root / 'Sources/quill/Info.plist')
        self.bin = self.root / 'tools'
        self.bin.mkdir()
        # In the test copy only, substitute a fixed trusted tools directory.
        # The production script exposes no override for its trusted PATH.
        script = script.replace('export PATH=/usr/bin:/bin:/usr/sbin:/sbin',
                                f'export PATH="{self.bin}:/usr/bin:/bin:/usr/sbin:/sbin"')
        script = script.replace('/usr/libexec/PlistBuddy', f'"{self.bin}/PlistBuddy"')
        script = script.replace('/usr/bin/xcrun', f'"{self.bin}/xcrun"')
        (self.root / 'scripts/install-app.sh').write_text(script)
        shutil.copy(REPO / 'scripts/assemble-app.sh', self.root / 'scripts/assemble-app.sh')
        helper = (REPO / 'scripts/app-plist.sh').read_text().replace(
            '/usr/libexec/PlistBuddy', f'"{self.bin}/PlistBuddy"')
        (self.root / 'scripts/app-plist.sh').write_text(helper)
        for relative in ['LICENSE', '.build/checkouts/FluidAudio/LICENSE',
                         '.build/checkouts/swift-argument-parser/LICENSE.txt']:
            target = self.root / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text('Fixture license\n')
        for tool in ['pgrep', 'xcrun', 'swift', 'security', 'codesign', 'openssl', 'PlistBuddy', 'open']:
            file = self.bin / tool
            file.write_text(TOOLS.replace('#!/usr/bin/env python3', '#!' + sys.executable))
            file.chmod(0o755)
        build = self.root / 'build'
        build.mkdir()
        (build / 'quill').write_text('fresh executable')
        self.app = self.root / 'Custom Apps/Quill.app'
        self.log = self.root / 'calls'
        self.env = {**os.environ, 'PATH': str(self.bin) + os.pathsep + os.environ['PATH'],
                    'QUILL_APP_PATH': str(self.app), 'BINARY_DIR': str(build), 'CALLS': str(self.log)}
        self.env.pop('QUILL_SIGNING_IDENTITY', None)

    def existing(self):
        (self.app / 'Contents/MacOS').mkdir(parents=True)
        (self.app / 'Contents/MacOS/quill').write_text('old executable')
        (self.app / 'Contents/unexpected.dylib').write_text('untrusted content')
        with (self.app / 'Contents/Info.plist').open('wb') as f:
            plistlib.dump({'CFBundleIdentifier': 'test.quill', 'InjectedSetting': 'untrusted'}, f)

    def run_installer(self, **env):
        return subprocess.run(['/bin/bash', str(self.root / 'scripts/install-app.sh')],
                              env={**self.env, **env}, capture_output=True, text=True)

    def calls(self):
        return [json.loads(line) for line in self.log.read_text().splitlines()]

    def assert_old_intact(self):
        self.assertEqual((self.app / 'Contents/MacOS/quill').read_text(), 'old executable')
        self.assertTrue((self.app / 'Contents/unexpected.dylib').exists())

    def test_fresh_bundle_only_preserves_identifier(self):
        self.existing()
        result = self.run_installer()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse((self.app / 'Contents/unexpected.dylib').exists())
        self.assertEqual((self.app / 'Contents/MacOS/quill').read_text(), 'fresh executable')
        with (self.app / 'Contents/Info.plist').open('rb') as f: info = plistlib.load(f)
        self.assertEqual(info['CFBundleIdentifier'], 'test.quill')
        self.assertNotIn('InjectedSetting', info)
        self.assertEqual(info['CFBundleName'], 'Quill Local')
        self.assertEqual(info['QuillVariant'], 'local')
        self.assertEqual(plistlib.loads(Path(str(self.log) + '.build-plist').read_bytes()), info)
        self.assertTrue(any('-R' in call for call in self.calls()))

    def test_distribution_app_is_never_replaced(self):
        self.existing()
        plist = self.app / 'Contents/Info.plist'
        plist.write_bytes(plistlib.dumps({'CFBundleIdentifier': 'io.github.enigma.quill'}))
        result = self.run_installer()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('distribution app', result.stderr)
        self.assert_old_intact()
        self.assertFalse(any(call[0] in ['swift', 'security', 'openssl'] for call in self.calls()))

    def test_identity_policy_can_change_without_script_edits(self):
        policy_path = self.root / 'Sources/quill/Info.plist'
        policy = plistlib.loads(policy_path.read_bytes())
        policy.update(QuillLocalIdentifier='example.local', QuillLocalName='Example Local',
                      CFBundleIdentifier='example.distribution')
        policy_path.write_bytes(plistlib.dumps(policy))
        result = self.run_installer()
        self.assertEqual(result.returncode, 0, result.stderr)
        installed = self.app / 'Contents/Info.plist'
        info = plistlib.loads(installed.read_bytes())
        self.assertEqual(info['CFBundleIdentifier'], 'example.local')
        self.assertEqual(info['CFBundleName'], 'Example Local')
        info['CFBundleIdentifier'] = 'example.distribution'
        installed.write_bytes(plistlib.dumps(info))
        result = self.run_installer()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('distribution app', result.stderr)

    def test_invalid_signature_is_untouched(self):
        self.existing()
        self.assertNotEqual(self.run_installer(INVALID='1').returncode, 0)
        self.assert_old_intact()
        self.assertFalse(any('--sign' in call for call in self.calls()))

    def test_different_identity_is_untouched(self):
        self.existing()
        self.assertNotEqual(self.run_installer(WRONG_KEY='1').returncode, 0)
        self.assert_old_intact()

    def test_missing_key_for_existing_app_does_not_generate(self):
        self.existing()
        self.assertNotEqual(self.run_installer(NO_KEY='1').returncode, 0)
        self.assert_old_intact()
        self.assertFalse(any(call[0] == 'openssl' for call in self.calls()))

    def test_first_install_creates_key_once(self):
        result = self.run_installer(NO_KEY='1')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(any(call[:2] == ['security', 'import'] for call in self.calls()))
        self.assertFalse(list(self.app.parent.glob('.quill-install.*')))
        self.log.write_text('')
        result = self.run_installer()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(any(call[0] == 'openssl' for call in self.calls()))
        self.assertFalse(any('add-trusted-cert' in call for call in self.calls()))

    def hostile_path(self):
        hostile = self.root / 'hostile'
        hostile.mkdir()
        marker = self.root / 'hostile-tool-executed'
        for tool in ['dirname', 'pgrep', 'codesign', 'security', 'openssl', 'swift', 'xcrun']:
            file = hostile / tool
            file.write_text(f'#!/bin/bash\n/bin/touch "{marker}"\nexit 99\n')
            file.chmod(0o755)
        return str(hostile), marker

    def test_caller_path_is_ignored_through_key_creation(self):
        hostile, marker = self.hostile_path()
        result = self.run_installer(PATH=hostile, NO_KEY='1')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(marker.exists())
        self.assertIn(['xcrun', '--find', 'swift'], self.calls())
        self.assertTrue(any(call[:2] == ['security', 'import'] for call in self.calls()))

    def test_unmodified_script_resets_path_before_first_command(self):
        hostile, marker = self.hostile_path()
        result = subprocess.run(['/bin/bash', str(REPO / 'scripts/install-app.sh')],
                                env={**self.env, 'PATH': hostile, 'QUILL_APP_PATH': 'relative.app'},
                                capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('absolute .app path', result.stderr)
        self.assertFalse(marker.exists())

    def test_relative_swift_resolution_is_rejected_before_key_creation(self):
        result = self.run_installer(NO_KEY='1', SWIFT_RESOLUTION='swift')
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(any(call[0] in ['swift', 'openssl'] for call in self.calls()))
        self.assertFalse(self.app.exists())

    def test_symlink_destination_is_rejected(self):
        self.app.parent.mkdir()
        self.app.symlink_to(self.root / 'elsewhere')
        self.assertNotEqual(self.run_installer().returncode, 0)
        self.assertTrue(self.app.is_symlink())


if __name__ == '__main__':
    unittest.main()
