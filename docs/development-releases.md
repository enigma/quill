# Development app downloads

This first milestone produces a preview ZIP locally and defines a GitHub Actions
workflow to produce the same artifact. It neither installs the app nor publishes a
GitHub Release. No signing certificate, Apple account, or custom GitHub secret is
needed for the ordinary preview. Optional persistent signing is described below.
Models are downloaded at runtime, not during packaging or tests.

## Persistent signing experiment

The `CI` workflow accepts a manual `sign_preview` boolean (default false). Signing
is allowed only for a manual run on `refs/heads/release`; pushes continue to build
ordinary ad-hoc previews. No PR trigger or automatic publication is added.

Configure the repository environment `signing` before running it:

- Require the maintainer's approval; leave prevent-self-review off for a solo
  maintainer, and disable administrator bypass.
- Allow only the branch `release`, with no tag rule.
- Store `SIGNING_CERTIFICATE_P12` (base64 of the encrypted P12) and
  `SIGNING_CERTIFICATE_PASSWORD` (its export password) as environment secrets.

Keep the P12 and its password backed up in a password manager. Neither belongs
in Git. Use a dedicated distribution identity, separate from `QuillLocalDev`.

After reviewing this change, integrate it into `dev` (the default branch), then
create `release` from the same reviewed commit and push both. GitHub requires
the workflow on the default branch for the manual dispatch UI. In Actions → CI →
Run workflow, select `release` and enable `sign_preview`. Alternatively:

```sh
gh workflow run ci.yml --repo enigma/quill --ref release -f sign_preview=true
```

The build job tests and packages without signing secrets. The signing job waits
for environment approval, checks out the run's commit, and downloads only that
run's matching preview artifact. Review the commit and workflow before approving.
Rerun the entire workflow if needed: rerunning only a failed signing job does not
produce an artifact with the new attempt number.

`scripts/sign-preview.py` checks the archive statically, imports the identity into
a temporary Keychain, signs with its certificate fingerprint, and verifies that
the signature matches. It never executes the app, installs dependencies, adds
certificate trust, or imports into the login/System Keychain. It restores the
Keychain search list and removes temporary credentials before publishing output.
Normal failures and termination trigger cleanup; a hard-killed hosted runner is
discarded by GitHub. Do not use this workflow on a shared/self-hosted runner.

Secrets are supplied only to the signing step and removed from the environment
inherited by its subprocesses. macOS's `security` utility accepts passwords as
process arguments, so the signing runner must be treated as trusted. Tool output
and command arguments are not dumped on errors. These controls do not make
malicious code in the approved job safe: anyone approving it must review changes
to the workflow and scripts it uses.

Download `Quill-signed-preview-arm64-<commit>-<build>-<attempt>` from the run. It contains
`Quill-macos-arm64-signed-preview.zip` and its SHA-256 sidecar; the ZIP contains
`download/Quill.app` and `BUILD.txt`, including the signing certificate fingerprint.
Only these two output files are uploaded. This is still a preview artifact, not a
GitHub Release, and it is not notarized.

Test build A at a fixed app location separate from the daily app, using the isolated
launcher below. Grant permissions and record both sources. Produce build B by
dispatching a new run (its build number changes), quit A, and replace it at the
same location. Do not reset permissions between A and B. Confirm both BUILD.txt
files name the same certificate fingerprint. Record Gatekeeper/Open Anyway prompts
separately from microphone and screen/system-audio prompts. A persistent self-signed
identity does not guarantee Gatekeeper acceptance; this experiment measures it.

## Automated friends prereleases

The existing workflow also accepts `release_tag`, for example `v0.1.0-beta.1`.
This implies signing and accepts only beta versions on a manual run of `release`.
It reuses the existing `signing` environment restricted to that branch; no new
secrets or tag permissions are needed. Ordinary pushes only test/build, and the
retired feature branch no longer triggers CI.

After committing, pushing, and promoting tested `dev` changes to `release`:

```sh
gh workflow run ci.yml --repo enigma/quill --ref release \
  -f release_tag=v0.1.0-beta.1
```

Approve the signing job after reviewing the selected commit. CI builds the numeric
version `0.1.0` with its unique run number, tests it, signs it, and passes the signed
ZIP to a separate publication job. Only that job has `contents: write`; it has no
signing environment or signing secrets. It checks the checksum, version, build,
commit, clean-tree provenance, app identity, and signing provenance before creating
a **draft prerelease** targeting the exact workflow commit. It does not rebuild,
execute, or change the signed app. Versioned release assets retain the signed ZIP's
bytes and get a checksum sidecar referring to their new filename.

Open the draft at https://github.com/enigma/quill/releases, download and test its
Quill ZIP, review the generated installation/permission/update notes, then click
**Publish release**. Drafts are not public download links. After publication, share
`https://github.com/enigma/quill/releases/tag/v0.1.0-beta.1` with friends. The ZIP is a
direct asset, without Actions' outer ZIP wrapper, and does not have the 14-day
Actions artifact expiry. The automatic Source code assets are not the app.

Do not pre-create a version tag. The workflow rejects existing tags and never
overwrites published assets. It also refuses to overwrite an existing draft. If
an upload fails, the draft may be incomplete: inspect it before deleting an
unpublished draft and retrying, or choose a new beta number. Rerun the whole
workflow to produce matching artifacts for the new attempt. Never move a public
tag or replace a published version's bytes.

This manual-dispatch draft flow supersedes the earlier tag-trigger proposal for
the self-signed beta. It preserves the release-only environment rule and leaves
one deliberate public Publish action after testing. Notarization, DMG packaging,
Homebrew, and built-in updates remain separate follow-ups.

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
