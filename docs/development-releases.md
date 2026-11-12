# Development app downloads

This first milestone produces a preview ZIP locally and defines a GitHub Actions
workflow to produce the same artifact. It neither installs the app nor publishes a
GitHub Release. No signing certificate, Apple account, or custom GitHub secret is
needed. Models are downloaded at runtime, not during packaging or tests.

## Local build and inspection

Run from an Apple Silicon Mac with macOS 15+ and Swift 6.1.2 or the CI-selected
Xcode 16.4 toolchain:

```sh
make test-capture test-installer
make build-app
python3 scripts/verify-preview.py dist/Quill-macos-arm64-preview.zip
```

Optional numeric metadata overrides:

```sh
QUILL_VERSION=0.1.0 QUILL_BUILD_NUMBER=2 make build-app
```

In Safehouse, enable `xcode` when starting the session. SwiftPM's nested sandbox
cannot start inside Safehouse; explicitly set `QUILL_DISABLE_SWIFTPM_SANDBOX=1`
for this build. This does not disable Safehouse. CI uses SwiftPM's default sandbox.

The output is `dist/Quill-macos-arm64-preview.zip` and a `.zip.sha256` sidecar.
Extracting it produces:

```text
download/
  BUILD.txt
  Quill.app/
```

`BUILD.txt` records the source commit, working-tree change count, compiler, SDK,
version, and architecture. `Quill.app` includes matching embedded/bundle metadata,
the dependency lockfile, and Quill/FluidAudio/ArgumentParser licenses. Assembly
copies only explicit inputs, not the working tree or an existing installation.
The verifier checks the extracted binary and bundle, not just the build directory.

The preview is ad-hoc signed, **not notarized**. The separate preview bundle ID
prevents it from claiming the installed development app's identity. It can still
use the same recordings configuration, so quit the existing Quill before any manual
capture test. Permissions for the preview may need to be granted separately.
Browser-downloaded previews are not yet the frictionless installation intended for
friends; Developer ID signing and notarization are later work.

`make install-app` remains the persistent-certificate local installation flow.
It shares the assembly helper but continues to preserve the installed identifier,
verify its signature, stop on a running app, and create/reuse the local signing key.

## CI behavior

`.github/workflows/ci.yml` runs on pushes to `dev`, `release`, and
`feat/release-pipeline`. Manual dispatch becomes available once the workflow exists
on the repository's default branch. All jobs have read-only repository permissions.
Opening or updating a PR does not trigger CI. External contributions must be reviewed
before being brought onto a named branch; merging code authorizes it to execute on
that branch's next build. Workflow and build-script changes need that same review.
Future signing jobs must be limited to protected release tags and a restricted
signing environment, never PR events or artifacts from untrusted runs.

1. Linux validates workflow syntax, security, and the action lockfile.
2. A fresh `macos-15` arm64 runner selects Xcode 16.4 explicitly, reports toolchain
   versions, runs tests, builds from `Package.resolved`, and verifies the archive.
3. It uploads only the preview ZIP and checksum, named by source SHA and run attempt,
   with 14-day retention. Failed jobs retain their normal Actions logs.

No shared build cache, PR artifact promotion, signing job, release publication,
or installation step is configured. Workflow artifacts require GitHub sign-in;
public downloads will use GitHub Release assets in a later milestone.

CI runner images can change; selecting an OS and Xcode version is not a guarantee
of byte-for-byte reproducibility. A removed Xcode version should fail clearly and
be updated deliberately, rather than falling back silently to a different compiler.

## Workflow dependency maintenance

Only GitHub's checkout and upload-artifact actions are used. Their exact versions,
repository/owner IDs, commits, and any action dependencies are recorded in
`.github/workflows/actions.lock`. Do not edit the lockfile manually.

`scripts/ci-tools.py` installs versioned SHA-256-verified copies of actionlint,
zizmor, and gh-actions-lock into ignored `.build/ci-tools`. It supports macOS arm64
and Linux x86_64. Pins come from upstream GitHub release asset metadata; review
upstream code/releases before changing versions and checksums. Downloads performed
inside actions are not automatically made immutable by the workflow lockfile.

```sh
python3 scripts/ci-tools.py
.build/ci-tools/actionlint
.build/ci-tools/zizmor --offline .github/workflows
.build/ci-tools/gh-actions-lock --verify
```

The online lock verifier uses an authenticated GitHub CLI locally and the read-only
job token in CI. It only reads GitHub data. If Safehouse blocks global Git config,
prefix the lock commands with `GIT_CONFIG_GLOBAL=/dev/null`.
After changing action references, run `.build/ci-tools/gh-actions-lock`, review the
lockfile diff, then rerun verification. `--verify-local` checks coverage offline but
does not replace the online provenance check. Dependabot proposes weekly updates;
updates are reviewed, not automatically merged.

## Remaining before public distribution

- A stable production identifier, icon, version policy, model notices, and documented
  migration from local development installs.
- Protected release branches/tags and a restricted signing environment.
- Developer ID identity, temporary signing Keychain, hardened runtime/entitlements,
  secure timestamps, notarization, stapling, and Gatekeeper verification.
- A tag-triggered release pipeline and browser-download testing on another Mac.
- Recording reliability gates, including interruption/write-failure testing.
- Homebrew and later Sparkle updates.

Do not interpret a successful CI build as proof that microphone/system capture or
permissions work on a real user's device. Those need explicit hardware tests.
