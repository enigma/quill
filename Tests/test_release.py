"""Release provenance and publication safety without network writes."""
import hashlib
import importlib.util
import os
from pathlib import Path
import plistlib
import subprocess
import tempfile
import unittest
from unittest.mock import patch
import zipfile

REPO = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location('release', REPO / 'scripts/release.py')
release = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(release)


class ReleaseTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.source = self.root / 'signed.zip'
        self.output = self.root / 'assets'
        self.sha = 'a' * 40
        self.tag = 'v0.1.0-beta.1'
        self.info = plistlib.loads((REPO / 'Sources/quill/Info.plist').read_bytes())
        self.info.update(CFBundleShortVersionString='0.1.0', CFBundleVersion='12')
        self.report = (f'Source commit: {self.sha}\nVersion: 0.1.0 (12)\n'
                       'Working tree changed paths: 0\nPersistent signing certificate SHA-1: ' + 'B' * 40 + '\n')

    def archive(self):
        with zipfile.ZipFile(self.source, 'w') as archive:
            archive.writestr('download/Quill.app/Contents/Info.plist', plistlib.dumps(self.info))
            archive.writestr('download/BUILD.txt', self.report)
        Path(str(self.source) + '.sha256').write_text(hashlib.sha256(self.source.read_bytes()).hexdigest())

    def prepare(self):
        return release.prepare(self.tag, self.sha, '12', self.source, self.output)

    def test_versioned_assets_preserve_signed_bytes_and_describe_limitations(self):
        self.archive()
        filename = self.prepare()
        self.assertEqual((self.output / filename).read_bytes(), self.source.read_bytes())
        self.assertEqual((self.output / (filename + '.sha256')).read_text().split()[1], filename)
        notes = (self.output / 'release-notes.md').read_text()
        for text in ('Open Anyway', 'not notarized', 'may repeat', 'interruption/recovery', self.sha):
            self.assertIn(text, notes)

    def test_wrong_version_or_commit_or_dirty_build_rejected(self):
        for info_key, info_value, report in [
                ('CFBundleVersion', '11', self.report),
                ('CFBundleShortVersionString', '0.2.0', self.report),
                ('CFBundleVersion', '12', self.report.replace(self.sha, 'c' * 40)),
                ('CFBundleVersion', '12', self.report.replace('paths: 0', 'paths: 1'))]:
            with self.subTest(info_key=info_key, info_value=info_value, report=report):
                self.info.update(CFBundleShortVersionString='0.1.0', CFBundleVersion='12')
                self.info[info_key] = info_value
                self.report = report
                self.archive()
                with self.assertRaises(ValueError):
                    self.prepare()
                self.assertFalse(self.output.exists())

    def test_checksum_mismatch_rejected(self):
        self.archive()
        self.source.write_bytes(self.source.read_bytes() + b'changed')
        with self.assertRaisesRegex(ValueError, 'checksum'):
            self.prepare()

    def test_tags_reject_stable_versions_and_shell_input(self):
        for tag in ('v0.1.0', 'v01.1.0-beta.1', 'v0.1.0-beta.0', 'v0.1.0-beta.1\nextra', '$(whoami)'):
            with self.subTest(tag=tag), self.assertRaises(ValueError):
                release.version_for(tag)

    def test_release_request_rejects_other_branches_and_events(self):
        for branch, event in [('refs/heads/dev', 'workflow_dispatch'), ('refs/heads/release', 'push')]:
            with patch.dict(os.environ, GITHUB_REF=branch, GITHUB_EVENT_NAME=event):
                with self.assertRaises(ValueError):
                    release.validate_request(self.tag)

    def test_publish_is_draft_prerelease_at_exact_commit_without_clobber(self):
        with patch.dict(os.environ, GH_REPO='example/quill'), \
                patch.object(release.subprocess, 'check_output', return_value='[]'), \
                patch.object(release.subprocess, 'run') as run:
            release.publish(self.tag, self.sha, self.output)
        args = run.call_args.args[0]
        self.assertIn('--draft', args)
        self.assertIn('--prerelease', args)
        self.assertEqual(args[args.index('--target') + 1], self.sha)
        self.assertNotIn('--clobber', args)

    def test_existing_tag_or_api_error_prevents_publication(self):
        for response in (f'[{{"ref":"refs/tags/{self.tag}"}}]', None):
            with patch.dict(os.environ, GH_REPO='example/quill'), \
                    patch.object(release.subprocess, 'check_output', return_value=response,
                                 side_effect=subprocess.CalledProcessError(1, 'gh') if response is None else None), \
                    patch.object(release.subprocess, 'run') as run:
                with self.assertRaises((ValueError, subprocess.CalledProcessError)):
                    release.publish(self.tag, self.sha, self.output)
                run.assert_not_called()
