"""Prepare versioned downloads and create a draft; never replace a published release."""
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import sys
import zipfile


def version_for(tag):
    match = re.fullmatch(r'v((?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*))-beta\.([1-9][0-9]*)', tag)
    if not match:
        raise ValueError('Use a prerelease tag such as v0.1.0-beta.1')
    return match[1]


def validate_request(tag):
    if not tag:
        return '0.1.0'
    if os.environ.get('GITHUB_REF') != 'refs/heads/release' or os.environ.get('GITHUB_EVENT_NAME') != 'workflow_dispatch':
        raise ValueError('Draft releases must be manually requested on release')
    return version_for(tag)


def prepare(tag, sha, build, source, output):
    version = version_for(tag)
    if not re.fullmatch(r'[0-9a-f]{40}', sha) or not re.fullmatch(r'[1-9][0-9]*', build):
        raise ValueError('Invalid commit or build number')
    checksum = hashlib.sha256(source.read_bytes()).hexdigest()
    if Path(str(source) + '.sha256').read_text().split()[0] != checksum:
        raise ValueError('Signed archive checksum mismatch')
    # Inspect without executing or extracting anything from the signing artifact.
    with zipfile.ZipFile(source) as archive:
        def read(name):
            matches = [entry for entry in archive.infolist() if entry.filename == name]
            if len(matches) != 1 or matches[0].file_size > 1024 * 1024:
                raise ValueError('Missing, duplicate, or oversized release metadata')
            return archive.read(matches[0])
        info = plistlib.loads(read('download/Quill.app/Contents/Info.plist'))
        report = read('download/BUILD.txt').decode()
    if info.get('CFBundleShortVersionString') != version or info.get('CFBundleVersion') != build:
        raise ValueError('Signed app version/build does not match this release')
    expected_id = plistlib.loads((Path(__file__).resolve().parents[1] / 'Sources/quill/Info.plist').read_bytes())['CFBundleIdentifier']
    if info.get('CFBundleIdentifier') != expected_id:
        raise ValueError('Unexpected app identity')
    for expected in (f'Source commit: {sha}', f'Version: {version} ({build})', 'Working tree changed paths: 0'):
        if expected not in report.splitlines():
            raise ValueError('Signed build provenance does not match this release')
    if not re.search(r'^Persistent signing certificate SHA-1: [0-9A-F]{40}$', report, re.MULTILINE):
        raise ValueError('Missing persistent signing provenance')
    output.mkdir(parents=True, exist_ok=False)
    filename = f'Quill-{tag}-macos-arm64.zip'
    shutil.copyfile(source, output / filename)
    (output / (filename + '.sha256')).write_text(f'{checksum}  {filename}\n')
    (output / 'release-notes.md').write_text(f'''Quill {tag} — experimental friends beta

Requires an Apple Silicon Mac and macOS 15 or later.

### Install

1. Download **{filename}** below (not the automatic Source code archives).
2. Unzip it and move `download/Quill.app` to Applications or another permanent app location.
3. Open Quill. If macOS says Apple could not verify it, click **Done**, then go to
   **System Settings → Privacy & Security → Security → Open Anyway**.
4. Allow microphone and screen/system-audio access when requested. A separate
   request to bypass the system private window picker is expected; choose **Allow**
   to enable direct capture. Check both audio indicators during a short test recording.

The app is self-signed and **not notarized by Apple**. These approvals may repeat
after updates, even with the same signing certificate. Do not install a certificate
or disable Gatekeeper. This is an experimental beta, not a stable recording guarantee;
long-call and interruption/recovery testing is still outstanding.

### Recordings and transcription

Recordings default to `~/Recordings`; settings live in `~/.config/quill/config.json`.
Parakeet v3 transcribes locally, including English and Italian. Its model downloads
on first use (internet and disk space required); model files are cached in
`~/Library/Application Support/FluidAudio/Models/`. Recordings stay on your Mac.
The app does not enable launch at login.

### Update or uninstall

Quit Quill, then replace the old app at the same location with the new one.
Keep your settings and recordings; no migration or permission reset is required
as an update step. There is no built-in updater yet.
To uninstall, quit and delete the app. Recordings, settings, and cached models
remain unless you choose to delete them separately.

### Build information

Commit: `{sha}` · Build: `{build}` · Version: `{version}`.
The SHA-256 sidecar verifies the ZIP; `download/BUILD.txt` includes build provenance
and the signing certificate fingerprint. License notices are inside the app bundle.
''')
    return filename


def publish(tag, sha, directory):
    version_for(tag)
    if not re.fullmatch(r'[0-9a-f]{40}', sha):
        raise ValueError('Invalid commit')
    repo = os.environ['GH_REPO']
    # Fail closed on API errors or existing tags. Never repoint a tag or clobber assets.
    refs = json.loads(subprocess.check_output(
        ['gh', 'api', f'repos/{repo}/git/matching-refs/tags/{tag}'], text=True))
    if any(ref['ref'] == f'refs/tags/{tag}' for ref in refs):
        raise ValueError('Tag already exists; choose a new version')
    filename = f'Quill-{tag}-macos-arm64.zip'
    subprocess.run(['gh', 'release', 'create', tag, '--repo', repo,
                    '--target', sha, '--draft', '--prerelease', '--latest=false',
                    '--title', f'Quill {tag}', '--notes-file', str(directory / 'release-notes.md'),
                    str(directory / filename), str(directory / (filename + '.sha256'))], check=True)


if __name__ == '__main__':
    tag = os.environ.get('RELEASE_TAG', '')
    version = validate_request(tag)
    mode = sys.argv[1] if len(sys.argv) == 2 else ''
    if mode == 'validate':
        with open(os.environ['GITHUB_OUTPUT'], 'a') as output:
            output.write(f'version={version}\n')
    elif mode == 'prepare':
        prepare(tag, os.environ['GITHUB_SHA'], os.environ['GITHUB_RUN_NUMBER'],
                Path('signed/Quill-macos-arm64-signed-preview.zip'), Path('release-assets'))
    elif mode == 'publish':
        publish(tag, os.environ['GITHUB_SHA'], Path('release-assets'))
    else:
        raise SystemExit('Usage: release.py validate|prepare|publish')
