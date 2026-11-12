# quill

This is a personal fork of [digimata/quill](https://github.com/digimata/quill),
maintained in [enigma/quill](https://github.com/enigma/quill).

A minimal, fully local macOS meeting recorder + transcriber. One menu-bar
click records your mic and all system audio as two separate tracks; when you
stop, quill transcribes both on-device and writes a speaker-tagged transcript.
Nothing ever leaves the machine.

Named for the feather. Sibling of [parrot](https://github.com/digimata/parrot), same skeleton: single
Swift binary, menu-bar tray, no app bundle.

## Install

```sh
cd quill
swift build -c release
sudo cp .build/release/quill /usr/local/bin/quill
quill install --launch-at-login   # optional — runs in the background on login
```

**Requires:** macOS 15+ (ScreenCaptureKit for system audio — no virtual device
or kernel extension). Apple Silicon recommended for transcription speed.

## Rebuilding the local app

Use a persistent code-signing certificate so macOS can recognize successive
builds and retain recording permissions. Ad-hoc signing (`codesign -s -`)
changes the app's identity on each rebuild.

Quit Quill, then build, sign, install, and reopen it with:

```sh
make install-app
```

The default destination is `~/Applications/Quill.app`. Override it with an
absolute path (use the same path for future updates):

```sh
QUILL_APP_PATH="$HOME/Other Apps/Quill.app" make install-app
```

The installer sets a fixed system `PATH` before running any external commands
and resolves Swift explicitly with `/usr/bin/xcrun --find swift`. Tools injected
through the caller's `PATH` are ignored.

Every install builds a **fresh bundle** from the compiled executable and the
repository's `Info.plist`. No code, resources, entitlements, or arbitrary plist
settings are copied from the installed app. For an update, the installer first
verifies the existing app's signature and retains only its validated bundle
identifier. A certificate-signed update must satisfy the previous app's
signing requirement before it can replace it. An invalid existing signature
stops installation rather than being repaired by re-signing its contents.

The installer reuses a **QuillLocalDev** identity (or **Quill Development**),
selected by certificate fingerprint. If neither exists and there is **no app
at the destination**, it creates a local code-signing certificate and private
key once, imports them into your default Keychain, and removes temporary key
files. The certificate lasts ten years and is restricted to code signing;
it is not a certificate authority. No certificate trust settings or recording
permissions are changed. Keychain may ask you to allow private-key access.

Keep the certificate and private key in Keychain for future builds. If an app
is already installed and its key is missing, the installer stops rather than
silently creating a new identity. It also refuses ad-hoc signing and ambiguous
certificate names. The script contains no personal private keys or credentials
and can be shared; each person's Keychain supplies their own signing identity.

You can use an existing Apple Development certificate instead:

```sh
QUILL_SIGNING_IDENTITY="Apple Development: Your Name (TEAMID)" make install-app
```

Switching from the current ad-hoc build to the certificate-signed build may
require **one last** permission reset. Quit Quill and run these commands for
the existing `local.quill.app` bundle, then start recording and grant access:

```sh
tccutil reset Microphone local.quill.app
tccutil reset ScreenCapture local.quill.app
open ~/Applications/Quill.app
```

Keep using the same certificate, bundle identifier, and app path afterward.
Do not copy unsigned or ad-hoc executables into the signed app manually.
Apple documents identity continuity in [Code Signing In Depth](https://developer.apple.com/library/archive/technotes/tn2206/)
and [Inside Code Signing: Requirements](https://developer.apple.com/documentation/technotes/tn3127-inside-code-signing-requirements).

## How to use

Quill checks free disk space on launch, every 30 seconds, and when you open
the menu. Below **10 GB** free on the startup or recordings disk, a red
warning appears in the menu with the remaining space, and a warning symbol
appears beside the menu-bar feather even while idle. The warning clears
automatically after space is freed. Recording remains available. This is a
low-space warning, not a guarantee that macOS will keep capture running above
that threshold.

1. **Run it** (`quill` in a terminal, or the LaunchAgent).
2. **Click the feather in the menu bar → Start recording (30′ adjustable).** First use prompts
   for microphone and Screen Recording permissions. Quill registers only the
   audio output; it doesn't receive or store screen frames. macOS may require
   one relaunch after permission is granted. While recording, the icon turns
   red with a running elapsed counter, and macOS shows the recording indicator.
3. Recordings **stop automatically after 30 minutes**. The menu shows elapsed
   time and time remaining. While recording, choose **Extend 10′**, **Extend 30′**,
   or **Extend 1h** to add time to the current deadline; extensions can be repeated.
   Each new recording starts with a fresh 30-minute limit.
4. Optionally choose **Set recording title…** before or during recording. The
   title is saved immediately in `title.txt` inside the session folder; edit it
   from the same menu. A title set while idle applies to the next recording only.
5. **Click → Stop recording** when the meeting ends (or let the timer stop it). Transcription starts
   automatically (the menu shows progress); a notification fires when the
   transcript is ready.

Each session lands in `~/Recordings/<yyyy.MM.dd-HHmm>/`:

| File | Contents |
|---|---|
| `mic.caf` | your side (default input device, AAC) |
| `system.caf` | everything the Mac played — the other side of the call (AAC) |
| `title.txt` | optional recording title, searchable with `rg` |
| `meta.json` | start/end timestamps, duration, per-track start offsets |
| `transcript.json` | canonical transcript — engine provenance + timed, speaker-tagged segments |
| `transcript.md` | the same transcript rendered for reading |
| `transcribe.log` | transcription progress/errors for this session |

Two tracks on purpose: speech models do better on clean single-source audio,
and mic-vs-system is free two-party diarization — `me` vs `them` with no
speaker-identification model. CAF on purpose: unlike m4a, it needs no
finalization pass — if the process dies mid-meeting, everything already
written is still readable.

## Transcription

Built in, on-device, automatic. The default model is **Parakeet TDT 0.6B v3**
via [FluidAudio](https://github.com/FluidInference/FluidAudio)'s Core ML port.
It automatically recognizes 25 European languages, including **English and
Italian**, without a language hint. Transcription speed depends on your Mac
and the recording.

The v3 models download once on first transcription and run locally afterward.
An existing v2 model cache does not replace the v3 download. Run `quill doctor`
to check v3 readiness, and transcribe a short test recording while online before
an important meeting. The `"engine": "parakeet"` config setting stays the same.
Existing completed transcripts are preserved; new and pending transcription
jobs use v3 and record `parakeet-tdt-0.6b-v3-coreml` in their provenance.

Each track is transcribed separately, shifted by its start offset so both
share one clock, and merged by timestamp. Jobs run in a serial queue — you can
start a new recording while the last one transcribes. Unfinished jobs resume
on next launch (the filesystem is the queue: a session with `meta.json` but no
`transcript.json` is pending). Failures append to the session's
`transcribe.log` and never block later jobs.

The engine sits behind a small protocol; a Whisper engine (WhisperKit
large-v3-turbo) is planned as the fallback / re-transcription option.

## Config

Optional, at `~/.config/quill/config.json`:

```json
{
  "recordings_dir": "~/Recordings",
  "transcription": { "enabled": true, "engine": "parakeet" },
  "on_stop": "my-hook"
}
```

- `recordings_dir` — where sessions land. Resolution order: `--out` flag >
  config > `~/Recordings`.
- `transcription.enabled` — set `false` to just record.
- `mic_voice_processing` — Apple's echo cancellation on the mic (default off).
  Set `true` when recording meetings through the speakers, so playback doesn't
  bleed into the mic track and get transcribed twice as "me". The trade: while
  the voice unit is live, macOS ducks other playback slightly (`.min` ducking
  is configured, but it can't be zeroed). On headphones there's no echo to
  cancel, so raw capture is the better default.
- `on_stop` — shell command spawned with the session directory as its
  argument, **after the transcript is written** (or right after recording if
  transcription is disabled). Wire it to whatever comes next: summarization,
  filing, indexing.

## CLI

```sh
quill                        # run the menu-bar daemon (^C to quit)
quill run --out <dir>        # custom recordings root (default ~/Recordings)
quill doctor                 # check permissions, recordings folder, models
quill install --launch-at-login
quill install --uninstall
```

## Stack

- **Swift** — single SPM executable target
- **ScreenCaptureKit** — audio-only system playback capture
- **AVAudioEngine** — mic capture
- **AVAudioFile** — streaming AAC encode into CAF
- **FluidAudio / Parakeet** — on-device Core ML transcription
- **NSStatusItem** — the whole UI

## Gotchas

- The system stream records *everything* the Mac plays — notification dings,
  music, all of it. Don't play Spotify during meetings (or ask for a
  per-process picker if it bothers you).
- If capture fails, check System Settings → Privacy & Security → Screen &
  System Audio Recording, then relaunch quill.
- Parakeet v3 supports 25 European languages; see its
  [supported languages](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3).
  Recognition can still make mistakes, especially with names and mixed-language speech.
- The binary embeds its Info.plist (`__TEXT,__info_plist`) so TCC can
  attribute permissions to quill itself when running as a LaunchAgent.

### Live capture status

While recording, open the Quill menu to see separate microphone and system-audio
level meters. “Receiving · saving” means audio buffers were successfully written;
“Quiet · saving” means buffers are arriving but their signal is very quiet. Silence
alone does not indicate a broken recorder.

After five seconds without incoming buffers or successful writes, the track shows
“No data” or “Not saving”. Explicit capture/write errors also show a warning.
A warning symbol remains visible on the menu-bar icon with the menu closed; hover
for details. These indicators do not automatically restart capture or prove that
both sides of a conversation are audible—test with speech and system playback.

Each recording has `logs/capture.log` with start/stop events, health transitions,
and successful frame counts. Capture warnings are also saved in `meta.json`.
Meters use in-memory audio counters, not repeated reads of the recording files.

Run `make test-capture` to check capture-health transitions. These standalone Swift
checks need only Command Line Tools and Foundation, not XCTest or model downloads.

### Development downloads

The release-pipeline prototype builds an **ad-hoc signed, unnotarized** Apple Silicon
preview for macOS 15+. It is not yet a public release. It uses the separate bundle
identifier `io.github.enigma.quill.preview`; the build does not install or open it.

```sh
make test-capture test-installer
make build-app
python3 scripts/verify-preview.py dist/Quill-macos-arm64-preview.zip
```

When building inside Safehouse, start it with `--enable=xcode` and use
`QUILL_DISABLE_SWIFTPM_SANDBOX=1 make build-app` to disable SwiftPM's nested sandbox.
The outer Safehouse sandbox remains active. Outside Safehouse, use the normal command.

See [the development build and CI guide](docs/development-releases.md) for the
artifact layout, workflow checks, and remaining production release work.
