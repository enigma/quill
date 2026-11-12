"""Install CI validators from explicit release assets with reviewed SHA-256 pins.

No installation into PATH or a user account; tools live in ignored .build/ci-tools.
Update versions and checksums together, reviewing the upstream release first.
"""
import hashlib
import io
from pathlib import Path
import platform
import tarfile
import urllib.request

# Digests from each upstream GitHub release's asset metadata.
TOOLS = {
    ('Darwin', 'arm64'): [
        ('gh-actions-lock',
         'https://github.com/github/gh-actions-lock/releases/download/v0.4.1/darwin-arm64',
         'f205ea5dbbda67165e08aab1fb6395290ca62f0a038bf27d4b684abd0816635c'),
        ('actionlint',
         'https://github.com/rhysd/actionlint/releases/download/v1.7.12/actionlint_1.7.12_darwin_arm64.tar.gz',
         'aba9ced2dee8d27fecca3dc7feb1a7f9a52caefa1eb46f3271ea66b6e0e6953f'),
        ('zizmor',
         'https://github.com/zizmorcore/zizmor/releases/download/v1.32.0/zizmor-aarch64-apple-darwin.tar.gz',
         '6efed18c4539a663fd3c851a2be9533fd8456c4e646d9416206da059154a0d3c'),
    ],
    ('Linux', 'x86_64'): [
        ('gh-actions-lock',
         'https://github.com/github/gh-actions-lock/releases/download/v0.4.1/linux-amd64',
         '39deb2fe714dbf74b073d8245fc7f3d50cd0eee18d5c0900e9e849ae933ae17e'),
        ('actionlint',
         'https://github.com/rhysd/actionlint/releases/download/v1.7.12/actionlint_1.7.12_linux_amd64.tar.gz',
         '8aca8db96f1b94770f1b0d72b6dddcb1ebb8123cb3712530b08cc387b349a3d8'),
        ('zizmor',
         'https://github.com/zizmorcore/zizmor/releases/download/v1.32.0/zizmor-x86_64-unknown-linux-gnu.tar.gz',
         'bb110cc765eca9cd7efb2e284a956be5974c60027b0970f16397d86208a9957b'),
    ],
}


def main():
    target = Path(__file__).resolve().parents[1] / '.build/ci-tools'
    target.mkdir(parents=True, exist_ok=True)
    for name, url, digest in TOOLS[(platform.system(), platform.machine())]:
        data = urllib.request.urlopen(url, timeout=60).read()
        if hashlib.sha256(data).hexdigest() != digest:
            raise SystemExit(f"Checksum mismatch for {name}")
        if url.endswith('.tar.gz'):
            with tarfile.open(fileobj=io.BytesIO(data), mode='r:gz') as archive:
                members = [m for m in archive.getmembers()
                           if Path(m.name).name == name and m.isfile()]
                if len(members) != 1:
                    raise SystemExit(f"Unexpected archive layout for {name}")
                data = archive.extractfile(members[0]).read()
        output = target / name
        output.write_bytes(data)
        output.chmod(0o755)
        print(f"Installed checksum-verified {name}")


if __name__ == '__main__':
    main()
