"""Sign an already-tested preview using an ephemeral Keychain; never run the app."""
import base64
import hashlib
import importlib.util
import os
from pathlib import Path
import re
import secrets
import shlex
import signal
import subprocess
import sys
import tempfile


def run(*args):
    # Never include command arguments or tool output in exceptions: security's
    # password arguments and diagnostic output may contain sensitive material.
    result = subprocess.run(args, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                            text=True, check=False)
    if result.returncode:
        raise RuntimeError(f'{Path(args[0]).name} {args[1]} failed (exit {result.returncode})')
    return result.stdout


def verify_static(archive):
    spec = importlib.util.spec_from_file_location(
        'verify_preview', Path(__file__).with_name('verify-preview.py'))
    verifier = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(verifier)
    verifier.verify(archive, run_app=False)


def sign(archive, destination):
    encoded = os.environ.pop('SIGNING_CERTIFICATE_P12', '')
    password = os.environ.pop('SIGNING_CERTIFICATE_PASSWORD', '')
    if not encoded or not password:
        raise ValueError('Both signing environment secrets must be set and nonempty')
    certificate = base64.b64decode(''.join(encoded.split()), validate=True)
    if not certificate:
        raise ValueError('Empty certificate')
    if destination.exists() or destination.is_symlink():
        raise ValueError('Output directory must not already exist')
    verify_static(archive)
    # Save the search list because creating/deleting a keychain can alter it.
    original_keychains = shlex.split(run('/usr/bin/security', 'list-keychains', '-d', 'user'))
    with tempfile.TemporaryDirectory(prefix='quill-signing-') as tmp:
        root = Path(tmp)
        keychain = str(root / 'signing.keychain-db')
        p12 = root / 'identity.p12'
        p12.write_bytes(certificate)
        p12.chmod(0o600)
        keychain_password = secrets.token_urlsafe(32)
        try:
            run('/usr/bin/security', 'create-keychain', '-p', keychain_password, keychain)
            run('/usr/bin/security', 'set-keychain-settings', '-lut', '600', keychain)
            run('/usr/bin/security', 'unlock-keychain', '-p', keychain_password, keychain)
            run('/usr/bin/security', 'list-keychains', '-d', 'user', '-s',
                keychain, *original_keychains)
            run('/usr/bin/security', 'import', str(p12), '-k', keychain,
                '-P', password, '-T', '/usr/bin/codesign')
            p12.unlink()
            run('/usr/bin/security', 'set-key-partition-list', '-S',
                'apple-tool:,apple:,codesign:', '-s', '-k', keychain_password, keychain)
            identities = run('/usr/bin/security', 'find-identity', '-p', 'codesigning', keychain)
            fingerprints = set(re.findall(r'\b[0-9A-F]{40}\b', identities))
            if len(fingerprints) != 1:
                raise ValueError('Expected exactly one code-signing identity in the P12')
            fingerprint = fingerprints.pop()
            extracted = root / 'extracted'
            run('/usr/bin/ditto', '-x', '-k', str(archive), str(extracted))
            app = extracted / 'download/Quill.app'
            run('/usr/bin/codesign', '--force', '--sign', fingerprint,
                '--keychain', keychain, '--timestamp=none', str(app))
            run('/usr/bin/codesign', '--verify', '--deep', '--strict',
                '-R', f'=certificate leaf = H"{fingerprint}"', str(app))
            with (extracted / 'download/BUILD.txt').open('a') as report:
                report.write(f'\nPersistent signing certificate SHA-1: {fingerprint}\n'
                             'Not notarized. Gatekeeper approval may still be required.\n')
            signed = root / 'Quill-macos-arm64-signed-preview.zip'
            run('/usr/bin/ditto', '-c', '-k', '--sequesterRsrc', '--keepParent',
                str(extracted / 'download'), str(signed))
            checksum = hashlib.sha256(signed.read_bytes()).hexdigest()
        finally:
            # A failed cleanup fails the job; no artifact is published first.
            try:
                if Path(keychain).exists():
                    run('/usr/bin/security', 'delete-keychain', keychain)
            finally:
                run('/usr/bin/security', 'list-keychains', '-d', 'user', '-s', *original_keychains)
        destination.mkdir(parents=True, exist_ok=False)
        (destination / signed.name).write_bytes(signed.read_bytes())
        (destination / (signed.name + '.sha256')).write_text(f'{checksum}  {signed.name}\n')
        print(f'Signed preview created; certificate SHA-1: {fingerprint}')


def interrupted(signum, frame):
    raise RuntimeError('Signing interrupted')


if __name__ == '__main__':
    signal.signal(signal.SIGTERM, interrupted)
    os.umask(0o077)
    if len(sys.argv) != 3:
        raise SystemExit('Usage: python3 scripts/sign-preview.py PREVIEW.zip NEW_OUTPUT_DIRECTORY')
    try:
        sign(Path(sys.argv[1]).resolve(), Path(sys.argv[2]).absolute())
    except (Exception, KeyboardInterrupt) as error:
        # No tracebacks or subprocess argument dumps in signing logs.
        print(f'Signing failed: {error}', file=sys.stderr)
        sys.exit(1)
