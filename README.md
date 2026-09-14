# Less Limitless

A native macOS 14+ foundation for a private, local-first pendant and meeting-audio library. It communicates directly with the pendant over Bluetooth Low Energy and contains no Limitless API integration.

## Implemented

- SwiftUI application shell for Library, Record, Pendant, Tasks, and Settings.
- Deferred Bluetooth permission: CoreBluetooth starts only after **Enable Bluetooth**.
- Service-filtered pendant discovery, explicit device selection, remembered reconnect, and battery reads.
- Non-destructive TimeSync, device info/status, and stored-page download commands.
- Bounded protobuf envelope decoding, fragmentation, and timeout-aware out-of-order reassembly.
- Domain models for recordings, transcripts, jobs, action items, sync verification, and durable library entries.
- A caller-rooted raw page vault with SHA-256, atomic Codable-ledger persistence, collision detection, and recovery-safe reloads.
- Cleanup eligibility requires persisted raw-page and audio hashes; no ACK or pendant deletion API is provided.
- Caller-rooted Opus packet-stream archives atomically persist length-framed `.opus.raw` streams with Codable SHA-256/byte-count manifests; packet boundaries survive archival, identical writes are idempotent, and mismatches collide without decode, ACK, or deletion.
- A durable vault-to-session pipeline reloads unverified raw pages, rechecks their SHA-256 hashes, reports failed/corrupt pages, assembles eligible Opus sessions, and writes deterministic SHA-256-derived archive IDs under a caller-supplied root without ACK or deletion.
- Packet-aligned `PendantSessionManifest` contributions can be decoded locally into immutable, atomic PCM16 WAV exports under a caller-rooted directory; source and WAV SHA-256 manifests make identical exports idempotent and conflicting session IDs collide without raw boundary inference, ACK, deletion, or network access.
- Golden wire fixtures and adversarial protocol tests.
- Local transcription jobs invoke only a user-configured local executable through Foundation `Process` (no shell or network), with regular-file validation, cancellation/timeout handling, bounded stdout/stderr capture, whisper.cpp JSON timestamps, and execution provenance.
- macOS 14-only `MacAudioCaptureService`: enumerates eligible ScreenCaptureKit applications, explicitly requests Screen Recording and optional microphone permission, captures system or selected-application audio plus an optional AVAudioEngine microphone track, and stores local segmented CAF files with an atomic crash-recovery `manifest.json` under a caller-supplied root; it performs no network access.

Stored page payloads can be parsed into bounded diagnostic summaries and raw audio payloads. Raw page vaults preserve received payloads without decoding, acknowledging, or deleting them; the app deliberately exposes no page deletion, storage clear, reset, Wi-Fi, backend, or key-injection commands.
Parsed summaries can be assembled with the pure, dependency-free `PendantSessionAssembler`. It deterministically groups pages from recording markers or five-minute timestamp gaps, exposes only unmodified eligible single-frame Opus codec bytes, and reports missing timestamps, encrypted audio, unsupported codecs, and invalid Opus frame counts without touching the raw vault or pendant.

## Build, test, and package (macOS)

### Prerequisites

- macOS 14 or newer
- Xcode 15 or newer, including Command Line Tools
- Swift 5.9 or newer (`swift --version`)
- Internet access on the first build to resolve [swift-crypto](https://github.com/apple/swift-crypto)
- libopus development files (`brew install opus` on macOS; `sudo dnf install opus-devel` on Fedora; `libopus-dev` on Debian/Ubuntu)

The Swift package resolves its dependencies automatically. Resolve them explicitly when preparing an offline build:

```sh
swift package resolve
```

### Run tests

```sh
# Debug tests
swift test

# Optimized release tests
swift test -c release
```

### Build the executable

```sh
# Debug executable
swift build -c debug --product LessLimitlessApp

# Optimized release executable
swift build -c release --product LessLimitlessApp

# Print the directory containing the selected build output
swift build -c release --show-bin-path
```

`swift build` produces a bare executable. Use the bundle command below for Bluetooth privacy strings and normal macOS app launching.

### Build a local `.app` bundle

```sh
# Debug bundle (default)
./build-app.sh

# Optimized release bundle
CONFIGURATION=release ./build-app.sh

# Launch the resulting app
open ".build/app/Less Limitless.app"
```

The bundling script copies `Resources/Info.plist`, including the Bluetooth, microphone, and screen-capture purpose strings, and ad-hoc signs the local bundle when `codesign` is available.

This is a local development package only. App Sandbox configuration, Developer ID signing, notarization, DMG packaging, and an auto-updater are not implemented yet.

## Current limitations

Raw Opus decoding is local-only and uses the system libopus library. It accepts a packet-aligned `[Data]` sequence of 16 kHz mono Opus packets, bounds packet/input/output sizes, and can encode decoded Float PCM as atomic PCM16 WAV files. Arbitrary concatenated raw bytes are deliberately rejected because the format has no safe packet delimiter. It does not invoke ffmpeg or any network service.

Mac audio capture is available only in the macOS 14+ app target; it is not built or claimed to work on Linux. The Record view captures system/application and optional microphone tracks into separately recoverable CAF segments with a local manifest. Local transcription requires a user-supplied compatible executable and model; it never downloads either. A Foundation-only, caller-rooted `LocalLibraryStore` atomically persists recording metadata, relative media references, transcript segments, notes, tags, processing state, and generated artifacts as JSON; it also provides local case/diacritic-insensitive token search. Optional OpenAI-compatible LLM providers are available only through explicit user configuration: loopback HTTP or remote HTTPS, text-only requests, and no redirects or Limitless hosts. Do not erase the pendant after a diagnostic page transfer. See `docs/PRODUCT_SPEC.md` for the architecture, safety requirements, and delivery phases.
