# Development app downloads

This first milestone produces a preview ZIP locally and defines a GitHub Actions
workflow to produce the same artifact. It neither installs the app nor publishes a
GitHub Release. No signing certificate, Apple account, or custom GitHub secret is
needed. Models are downloaded at runtime, not during packaging or tests.

## Local build and inspection

Run from an Apple Silicon Mac with macOS 15+ and Swift 6.1.2 or the CI-selected
Xcode 16.4 toolchain:

```sh
make test-capture test-separation test-installer
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

The preview remains ad-hoc signed, **not notarized**, but now uses the final
accepted distribution identity `io.github.enigma.quill`. Its name is **Quill**.
The `preview` archive filename describes its testing status, not a separate app ID.
GitHub and Homebrew will distribute this same app. There is no `install` login-agent command. Building or unpacking the app does not
enable autorun.

Identity policy is defined once in `Sources/quill/Info.plist`: its top-level
identifier/name define Quill, and `QuillLocal*` defines the local override. `scripts/app-plist.sh` applies that policy for both packaging
paths. Swift reads the resulting bundle metadata, including when run from a terminal. Existing
local installation IDs are still preserved rather than migrated.

## Side-by-side use with the daily local app

| | Distribution | Daily local installation |
|---|---|---|
| Bundle identifier | `io.github.enigma.quill` | Existing ID, normally `local.quill.app` |
| Display/menu name | Quill | Quill Local (after rebuilding) |
| Installation | Intended for `/Applications/Quill.app` | `~/Applications/Quill.app` |
| Signing today | Ad-hoc preview | Existing persistent local certificate |
| Normal config | `~/.config/quill/config.json` | Existing config, unchanged |
| Normal recordings | Configured path, otherwise `~/Recordings` | Existing path, unchanged |

Normal paths deliberately have no release suffix. Bundle IDs distinguish app
permissions; they do not isolate data. To test either app alongside the daily one,
run it with its own explicit test directory:

```sh
/bin/bash scripts/run-isolated.sh "/absolute/path/to/Quill.app" "$HOME/tmp/quill-test" --check
/bin/bash scripts/run-isolated.sh "/absolute/path/to/Quill.app" "$HOME/tmp/quill-test"
```

The first command reports identity and paths without launching UI/capture or checking
permissions. The second opens a new app instance through macOS LaunchServices,
passing the isolated paths explicitly. This avoids launching capture as a child of
the terminal, which can change macOS permission attribution. Quit this instance
through its menu; Ctrl-C in the terminal does not stop it. If Gatekeeper requires
Open Anyway, approve it, quit the relaunched app, then rerun the helper so the test
paths are applied. Confirm those paths in the app menu before recording.
The helper creates `config.json` with `{}` only
if absent, preserves an existing test config, and directs recordings and pending
transcription scans to `recordings/` under the test directory. It does not modify the
app bundle or the normal configuration. Customize only this test config as needed.
Test runs do not inherit the daily config's hooks. Downloaded model caches can be
shared; they contain model data, not meeting recordings.

Equivalent overrides for scripting are `QUILL_CONFIG_PATH` and
`QUILL_RECORDINGS_DIR`. Recording path precedence is `--out`, environment override,
selected config, then the normal default. The menu shows the active config and
recordings paths; the local variant also has a “Local” menu-bar label.

Updated builds hold `.quill.lock` in the selected recordings directory for their
whole lifetime, including transcription. A second instance cannot use the same
root concurrently. Locks release on quit/crash; do not delete the lock file while
an app is running. **An older daily build does not take this lock**, so use the
isolated launcher until you have rebuilt it. No files are automatically migrated.

`make install-app` remains the persistent-certificate local installation flow.
It now embeds matching local metadata, preserves the installed ID/signing requirement,
and labels the app Quill Local. It refuses to overwrite a distribution app even
if `QUILL_APP_PATH` points at it. It still asks you to quit running Quill processes
before replacing the daily app, and never modifies configuration or recordings.

Terminal execution uses the selected build’s identity; there is no third CLI
variant. The login-agent command has been removed. Existing login agents are not
changed or removed automatically, so this does not disturb an older installation.

Browser-downloaded previews are not yet the frictionless installation intended for
friends. Persistent distribution signing and the two-version update test are next;
Developer ID signing/notarization remains an optional paid route.

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

- App icon, version policy, model notices, and a tested transition from local
  development use to the distributed app with no data loss.
- Protected release branches/tags and a restricted signing environment.
- Developer ID identity, temporary signing Keychain, hardened runtime/entitlements,
  secure timestamps, notarization, stapling, and Gatekeeper verification.
- A tag-triggered release pipeline and browser-download testing on another Mac.
- Recording reliability gates, including interruption/write-failure testing.
- Homebrew and later Sparkle updates.

Do not interpret a successful CI build as proof that microphone/system capture or
permissions work on a real user's device. Those need explicit hardware tests.
