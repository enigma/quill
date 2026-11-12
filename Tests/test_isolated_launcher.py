"""Exercise launch isolation without starting AppKit or capture."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

REPO = Path(__file__).resolve().parents[1]


class IsolatedLauncherTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.app = self.root / 'App With Spaces.app'
        binary = self.app / 'Contents/MacOS/quill'
        binary.parent.mkdir(parents=True)
        binary.write_text('#!' + sys.executable + '''
import json, os, sys
print(json.dumps({'config': os.environ['QUILL_CONFIG_PATH'],
                  'recordings': os.environ['QUILL_RECORDINGS_DIR'],
                  'args': sys.argv[1:]}))
''')
        binary.chmod(0o755)
        self.data = self.root / 'test data'
        # Substitute only LaunchServices: never open an actual GUI app in tests.
        opener = self.root / 'open-stub'
        opener.write_text('#!' + sys.executable + '\nimport json, sys\nprint(json.dumps(sys.argv[1:]))\n')
        opener.chmod(0o755)
        self.launcher = self.root / 'run-isolated.sh'
        source = (REPO / 'scripts/run-isolated.sh').read_text()
        self.assertIn('exec /usr/bin/open ', source)
        self.launcher.write_text(source.replace('exec /usr/bin/open ', f'exec "{opener}" '))

    def launch(self, *args):
        return subprocess.run(['/bin/bash', str(self.launcher),
                               str(self.app), str(self.data), *args],
                              env={**os.environ, 'QUILL_CONFIG_PATH': '/daily/config.json',
                                   'QUILL_RECORDINGS_DIR': '/daily/recordings'},
                              capture_output=True, text=True)

    def test_launch_overrides_inherited_daily_paths(self):
        result = self.launch()
        self.assertEqual(result.returncode, 0, result.stderr)
        arguments = json.loads(result.stdout.splitlines()[-1])
        self.assertEqual(arguments, [
            '-n', '-a', str(self.app),
            '--env', f'QUILL_CONFIG_PATH={self.data.resolve()}/config.json',
            '--env', f'QUILL_RECORDINGS_DIR={self.data.resolve()}/recordings',
            '--args', 'run'])
        self.assertEqual(json.loads((self.data / 'config.json').read_text()), {})

    def test_check_only_preserves_existing_test_config(self):
        self.data.mkdir()
        config = self.data / 'config.json'
        config.write_text('{"transcription":{"enabled":false}}')
        before = config.read_bytes()
        result = self.launch('--check')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout.splitlines()[-1])['args'], ['doctor', '--paths-only'])
        self.assertEqual(config.read_bytes(), before)

    def test_config_symlink_is_not_followed(self):
        self.data.mkdir()
        original = self.root / 'daily.json'
        original.write_text('unchanged')
        (self.data / 'config.json').symlink_to(original)
        result = self.launch()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(original.read_text(), 'unchanged')

    def test_recordings_symlink_is_not_followed(self):
        self.data.mkdir()
        (self.data / 'recordings').symlink_to(self.root / 'daily-recordings')
        self.assertNotEqual(self.launch().returncode, 0)
        self.assertFalse((self.root / 'daily-recordings').exists())
