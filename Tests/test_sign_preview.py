"""Test signing boundaries and cleanup without accessing any real Keychain."""
import base64
import importlib.util
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

SCRIPT = Path(__file__).resolve().parents[1] / 'scripts/sign-preview.py'
SPEC = importlib.util.spec_from_file_location('sign_preview', SCRIPT)
signer = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(signer)


class SigningTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.output = Path(self.tmp.name) / 'signed'
        self.calls = []
        self.failure = None
        self.fingerprint = 'A' * 40
        self.addCleanup(patch.stopall)
        patch.dict(signer.os.environ, {
            'SIGNING_CERTIFICATE_P12': base64.b64encode(b'fake p12').decode(),
            'SIGNING_CERTIFICATE_PASSWORD': 'test-secret',
        }).start()
        self.verify = patch.object(signer, 'verify_static').start()
        patch.object(signer, 'run', side_effect=self.fake_run).start()

    def fake_run(self, *args):
        self.calls.append(args)
        self.assertNotIn('SIGNING_CERTIFICATE_PASSWORD', signer.os.environ)
        self.assertNotIn('SIGNING_CERTIFICATE_P12', signer.os.environ)
        if args[1] == self.failure:
            raise RuntimeError('injected failure')
        if args[1] == 'list-keychains' and '-s' not in args:
            return '"/original keychain"\n'
        if args[1] == 'create-keychain':
            Path(args[-1]).touch()
        if args[1] == 'delete-keychain':
            Path(args[-1]).unlink()
        if args[1] == 'import':
            p12 = Path(args[2])
            self.assertEqual(p12.read_bytes(), b'fake p12')
            self.assertEqual(p12.stat().st_mode & 0o777, 0o600)
        if args[1] == 'find-identity':
            return f'1) {self.fingerprint} "QuillDistribution"'
        if args[0] == '/usr/bin/ditto':
            if args[1] == '-x':
                download = Path(args[-1]) / 'download'
                (download / 'Quill.app').mkdir(parents=True)
                (download / 'BUILD.txt').write_text('Build provenance\n')
            else:
                Path(args[-1]).write_bytes(b'signed archive')
        return ''

    def test_success_publishes_only_archive_and_checksum_after_cleanup(self):
        signer.sign(Path('input.zip'), self.output)
        self.verify.assert_called_once_with(Path('input.zip'))
        self.assertEqual(len(list(self.output.iterdir())), 2)
        signing = next(call for call in self.calls if '--sign' in call)
        self.assertIn(self.fingerprint, signing)
        keychain = signing[signing.index('--keychain') + 1]
        self.assertIn(('/usr/bin/security', 'list-keychains', '-d', 'user', '-s',
                       keychain, '/original keychain'), self.calls)
        verification = next(call for call in self.calls if '-R' in call)
        self.assertIn(f'=certificate leaf = H"{self.fingerprint}"', verification)
        self.assertEqual(self.calls[-1], ('/usr/bin/security', 'list-keychains',
                                        '-d', 'user', '-s', '/original keychain'))
        self.assertFalse(Path(keychain).exists())
        self.assertTrue(all(call[0] in ('/usr/bin/security', '/usr/bin/codesign', '/usr/bin/ditto')
                            for call in self.calls))

    def test_import_failure_cleans_up_without_publishing(self):
        self.failure = 'import'
        with self.assertRaisesRegex(RuntimeError, 'injected failure'):
            signer.sign(Path('input.zip'), self.output)
        self.assertFalse(self.output.exists())
        deleted = next(call[-1] for call in self.calls if call[1] == 'delete-keychain')
        self.assertFalse(Path(deleted).parent.exists())
        self.assertEqual(self.calls[-1][-1], '/original keychain')

    def test_verification_failure_cleans_up_without_publishing(self):
        self.failure = '--verify'
        with self.assertRaises(RuntimeError):
            signer.sign(Path('input.zip'), self.output)
        self.assertFalse(self.output.exists())
        self.assertTrue(any(call[1] == 'delete-keychain' for call in self.calls))

    def test_existing_output_is_never_overwritten(self):
        self.output.mkdir()
        with self.assertRaisesRegex(ValueError, 'already exist'):
            signer.sign(Path('input.zip'), self.output)
        self.assertFalse(self.calls)

    def test_multiple_identities_rejected(self):
        self.fingerprint += '\n' + 'B' * 40
        with self.assertRaisesRegex(ValueError, 'exactly one'):
            signer.sign(Path('input.zip'), self.output)
        self.assertFalse(any('--sign' in call for call in self.calls))


class DiagnosticTests(unittest.TestCase):
    def test_subprocess_failure_does_not_disclose_password_or_output(self):
        with patch.object(signer.subprocess, 'run', return_value=subprocess.CompletedProcess(
                [], 1, stdout='secret stdout', stderr='secret stderr')):
            with self.assertRaises(RuntimeError) as caught:
                signer.run('/usr/bin/security', 'import', '-P', 'secret password')
        self.assertEqual(str(caught.exception), 'security import failed (exit 1)')
