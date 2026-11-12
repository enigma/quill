"""Verify the extracted development download, without launching recording/UI."""
import hashlib
import os
from pathlib import Path, PurePosixPath
import plistlib
import re
import stat
import struct
import subprocess
import sys
import tempfile
import zipfile

REPO = Path(__file__).resolve().parents[1]
EXPECTED = {
    'Contents/Info.plist', 'Contents/MacOS/quill',
    'Contents/Resources/Package.resolved',
    'Contents/Resources/Licenses/Quill.txt',
    'Contents/Resources/Licenses/FluidAudio.txt',
    'Contents/Resources/Licenses/ArgumentParser.txt',
    'Contents/_CodeSignature/CodeResources',
}


def embedded_plist(binary):
    """Read __TEXT,__info_plist from our thin arm64 Mach-O, independent of otool formatting."""
    data = binary.read_bytes()
    magic, cpu = struct.unpack_from('<II', data)
    if (magic, cpu) != (0xFEEDFACF, 0x0100000C):
        raise ValueError('Expected a thin arm64 Mach-O')
    ncmds = struct.unpack_from('<I', data, 16)[0]
    offset = 32
    for _ in range(ncmds):
        cmd, size = struct.unpack_from('<II', data, offset)
        if size < 8 or offset + size > len(data):
            raise ValueError('Malformed Mach-O command')
        if cmd == 0x19:  # LC_SEGMENT_64
            nsects = struct.unpack_from('<I', data, offset + 64)[0]
            for i in range(nsects):
                section = offset + 72 + i * 80
                name, segment = struct.unpack_from('<16s16s', data, section)
                if name.rstrip(b'\0') == b'__info_plist' and segment.rstrip(b'\0') == b'__TEXT':
                    length, start = struct.unpack_from('<QI', data, section + 40)
                    return plistlib.loads(data[start:start + length].rstrip(b'\0'))
        offset += size
    raise ValueError('Missing embedded Info.plist')


def check_archive_paths(archive):
    for entry in archive.infolist():
        path = PurePosixPath(entry.filename)
        if path.is_absolute() or '..' in path.parts or stat.S_ISLNK(entry.external_attr >> 16):
            raise ValueError(f'Unsafe archive member: {entry.filename}')


def verify(archive_path):
    archive_path = archive_path.resolve()
    checksum = Path(str(archive_path) + '.sha256').read_text().split()[0]
    if hashlib.sha256(archive_path.read_bytes()).hexdigest() != checksum:
        raise ValueError('Archive checksum mismatch')
    with zipfile.ZipFile(archive_path) as archive:
        check_archive_paths(archive)
    with tempfile.TemporaryDirectory(prefix='quill-preview-check-') as tmp:
        subprocess.run(['/usr/bin/ditto', '-x', '-k', str(archive_path), tmp], check=True)
        root = Path(tmp) / 'download'
        if {p.name for p in root.iterdir()} != {'Quill.app', 'BUILD.txt'}:
            raise ValueError('Unexpected download contents')
        app = root / 'Quill.app'
        files = {p.relative_to(app).as_posix() for p in app.rglob('*') if p.is_file()}
        if files != EXPECTED:
            raise ValueError(f'Unexpected app contents: {files.symmetric_difference(EXPECTED)}')
        binary = app / 'Contents/MacOS/quill'
        info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
        if embedded_plist(binary) != info:
            raise ValueError('Embedded and bundle Info.plist differ')
        expected_info = {
            'CFBundleIdentifier': 'io.github.enigma.quill.preview',
            'CFBundleExecutable': 'quill', 'CFBundlePackageType': 'APPL',
            'LSUIElement': True, 'LSMinimumSystemVersion': '15.0',
        }
        for key, value in expected_info.items():
            if info.get(key) != value:
                raise ValueError(f'Incorrect metadata: {key}')
        if not re.fullmatch(r'\d+\.\d+\.\d+', info['CFBundleShortVersionString']):
            raise ValueError('Invalid version')
        if not re.fullmatch(r'[1-9]\d*', info['CFBundleVersion']):
            raise ValueError('Invalid build number')
        if not os.access(binary, os.X_OK):
            raise ValueError('Executable permission missing after extraction')
        for key in ['NSMicrophoneUsageDescription', 'NSScreenCaptureUsageDescription']:
            if not info.get(key):
                raise ValueError(f'Missing permission description: {key}')
        if (app / 'Contents/Resources/Package.resolved').read_bytes() != (REPO / 'Package.resolved').read_bytes():
            raise ValueError('Packaged dependency lock differs')
        for license_file in (app / 'Contents/Resources/Licenses').iterdir():
            if not license_file.read_text().strip():
                raise ValueError('Empty license notice')
        subprocess.run(['/usr/bin/codesign', '--verify', '--deep', '--strict', str(app)], check=True)
        load_commands = subprocess.check_output(['/usr/bin/otool', '-l', str(binary)], text=True)
        if not re.search(r'\bminos 15\.0(?:\.0)?\s', load_commands):
            raise ValueError('Unexpected binary minimum macOS version')
        deps = subprocess.check_output(['/usr/bin/otool', '-L', str(binary)], text=True)
        for line in deps.splitlines()[1:]:
            dep = line.strip().split(' (', 1)[0]
            if not dep.startswith(('/System/Library/', '/usr/lib/')):
                raise ValueError(f'Unpackaged dynamic dependency: {dep}')
        subprocess.run([str(binary), '--help'], check=True, stdout=subprocess.DEVNULL)
        print('Preview verified: arm64, metadata, licenses, signature, dependencies, executable and archive.')


if __name__ == '__main__':
    if len(sys.argv) != 2:
        raise SystemExit('Usage: python3 scripts/verify-preview.py PREVIEW.zip')
    verify(Path(sys.argv[1]))
