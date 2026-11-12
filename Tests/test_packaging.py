"""Packaging boundaries; fixtures never build Swift or access the Keychain."""
import importlib.util
import io
import os
from pathlib import Path
import plistlib
import shutil
import stat
import subprocess
import tempfile
import unittest
import zipfile

REPO = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('verify_preview', REPO / 'scripts/verify-preview.py')
verifier = importlib.util.module_from_spec(spec)
spec.loader.exec_module(verifier)


class PackagingTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        (self.root / 'scripts').mkdir()
        shutil.copy(REPO / 'scripts/assemble-app.sh', self.root / 'scripts/assemble-app.sh')
        shutil.copy(REPO / 'scripts/build-app.sh', self.root / 'scripts/build-app.sh')
        self.binary = self.root / 'quill'
        self.binary.write_text('test executable')
        self.plist = self.root / 'Info.plist'
        self.plist.write_bytes(plistlib.dumps({'CFBundleIdentifier': 'fixture.quill'}))
        for path in ['LICENSE', '.build/checkouts/FluidAudio/LICENSE',
                     '.build/checkouts/swift-argument-parser/LICENSE.txt']:
            target = self.root / path
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text('test license')
        self.app = self.root / 'Output With Spaces/Quill.app'

    def assemble(self):
        return subprocess.run(['/bin/bash', str(self.root / 'scripts/assemble-app.sh'),
                               str(self.binary), str(self.plist), str(self.app)],
                              capture_output=True, text=True)

    def test_assembly_only_copies_explicit_files(self):
        (self.root / 'private-recording.caf').write_text('must not ship')
        (self.root / '.build/checkouts/FluidAudio/private.key').write_text('must not ship')
        result = self.assemble()
        self.assertEqual(result.returncode, 0, result.stderr)
        actual = {p.relative_to(self.app).as_posix() for p in self.app.rglob('*') if p.is_file()}
        self.assertEqual(actual, verifier.EXPECTED - {
            'Contents/Resources/Package.resolved', 'Contents/_CodeSignature/CodeResources'})
        self.assertTrue(os.access(self.app / 'Contents/MacOS/quill', os.X_OK))
        self.assertEqual((self.app / 'Contents/Info.plist').read_bytes(), self.plist.read_bytes())

    def test_existing_output_is_never_overwritten(self):
        self.app.mkdir(parents=True)
        marker = self.app / 'keep'
        marker.write_text('existing')
        self.assertNotEqual(self.assemble().returncode, 0)
        self.assertEqual(marker.read_text(), 'existing')

    def test_symlink_output_is_rejected(self):
        self.app.parent.mkdir()
        self.app.symlink_to(self.root / 'elsewhere')
        self.assertNotEqual(self.assemble().returncode, 0)
        self.assertFalse((self.root / 'elsewhere').exists())

    def test_missing_dependency_license_fails(self):
        (self.root / '.build/checkouts/FluidAudio/LICENSE').unlink()
        self.assertNotEqual(self.assemble().returncode, 0)

    def test_version_and_build_inputs_fail_before_building(self):
        for version, build in [('1.2;touch bad', '1'), ('1.2.3', '0'), ('1.2.3', '../x')]:
            with self.subTest(version=version, build=build):
                result = subprocess.run(['/bin/bash', str(self.root / 'scripts/build-app.sh')],
                    env={**os.environ, 'QUILL_VERSION': version, 'QUILL_BUILD_NUMBER': build},
                    capture_output=True, text=True)
                self.assertEqual(result.returncode, 2)
                self.assertFalse((self.root / 'dist').exists())

    def test_dist_symlink_is_rejected(self):
        (self.root / 'dist').symlink_to(self.root / 'elsewhere')
        result = subprocess.run(['/bin/bash', str(self.root / 'scripts/build-app.sh')],
                                capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('real directory', result.stderr)

    def test_archive_traversal_and_symlinks_are_rejected(self):
        for name, mode in [('../outside', 0), ('/absolute', 0), ('download/link', stat.S_IFLNK | 0o777)]:
            with self.subTest(name=name), io.BytesIO() as data:
                with zipfile.ZipFile(data, 'w') as archive:
                    entry = zipfile.ZipInfo(name)
                    entry.external_attr = mode << 16
                    archive.writestr(entry, 'target')
                data.seek(0)
                with zipfile.ZipFile(data) as archive, self.assertRaises(ValueError):
                    verifier.check_archive_paths(archive)


if __name__ == '__main__':
    unittest.main()
