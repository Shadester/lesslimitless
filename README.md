# Less Limitless

A private, local-first macOS app for the Limitless Pendant and Mac audio capture.

Less Limitless connects to the pendant directly over Bluetooth Low Energy, stores recordings on your Mac, and is designed to work without a Limitless account or any Limitless API endpoint.

> **Project status:** active foundation. The portable core is tested on Linux; Bluetooth, ScreenCaptureKit, microphone permissions, and SwiftUI must still be validated on a Mac.

## Highlights

- **Direct pendant BLE access** — discovery, pairing trigger, battery reading, status/info requests, and non-destructive stored-page download.
- **Safe local sync** — raw flash pages are hash-verified, stored atomically, and never acknowledged or erased automatically.
- **Pendant audio pipeline** — bounded protobuf parsing, session grouping, Opus packet provenance, libopus decode, and WAV export.
- **Mac capture** — ScreenCaptureKit system or per-app audio plus optional microphone input, written as recoverable CAF segments with a manifest.
- **Local library and search** — durable recording metadata, notes, tags, transcript segments, generated artifacts, and diacritic-insensitive full-text search.
- **Local transcription** — runs a user-supplied whisper.cpp-compatible executable through `Process`; no shell or network calls.
- **Optional LLM providers** — explicit OpenAI-compatible, text-only requests. HTTP is limited to loopback; remote providers require HTTPS; redirects and Limitless hosts are blocked.

## Privacy and safety

- No Limitless API, account, ingestion, or cloud dependency.
- No telemetry, analytics, or remote logging.
- Pendant erase, ACK, reset, Wi-Fi, backend, and key-injection commands are not exposed.
- Raw pendant data is preserved before parsing or decoding.
- Local LLMs can run over loopback. External providers are opt-in and receive transcript text only.
- Provider credentials are not persisted by the current app UI; use macOS Keychain before shipping a configured provider workflow.

## Requirements

### macOS app

- macOS 14+
- Xcode 15+ / Swift 5.9+
- [libopus](https://opus-codec.org/):

```sh
brew install opus
```

### Linux core tests

```sh
sudo dnf install swift-lang opus-devel
```

For Debian/Ubuntu, install `libopus-dev` plus a Swift toolchain.

## Build and run

Clone the repository and resolve dependencies:

```sh
git clone https://github.com/Shadester/lesslimitless.git
cd lesslimitless
swift package resolve
```

Run the portable test suite:

```sh
swift test
swift test -c release
```

Build the macOS executable:

```sh
swift build -c debug --product LessLimitlessApp
swift build -c release --product LessLimitlessApp
```

Create a local development app bundle:

```sh
./scripts/build-macos.sh --debug
open "dist/Less Limitless.app"
```

Create a signed release DMG:

```sh
./scripts/build-macos.sh \
  --identity "Developer ID Application: Your Name (TEAMID)" \
  --version 0.1.0 --build 1 --dmg --test
```

To notarize, first create an `xcrun notarytool` Keychain profile on the Mac, then run:

```sh
./scripts/build-macos.sh \
  --identity "Developer ID Application: Your Name (TEAMID)" \
  --notary-profile lesslimitless-notary --notarize --dmg
```

The script embeds Homebrew's `libopus`, rewrites its load path to the app bundle, signs nested code before the app, verifies the signature, and staples notarized output. It never stores Apple credentials in the repository.

## GitHub Actions releases

`CI` runs on pushes and pull requests to `main`. Pushing a tag such as `v0.1.0` triggers the release workflow, which signs, notarizes, staples, and attaches a DMG to a GitHub Release.

Configure these repository secrets before pushing a release tag:

| Secret | Purpose |
| --- | --- |
| `BUILD_CERTIFICATE_BASE64` | Base64-encoded Developer ID Application `.p12` |
| `P12_PASSWORD` | Password for the `.p12` |
| `KEYCHAIN_PASSWORD` | Temporary CI keychain password |
| `APPLE_API_KEY_BASE64` | Base64-encoded App Store Connect API `.p8` key |
| `APPLE_API_KEY_ID` | App Store Connect API key ID |
| `APPLE_API_ISSUER_ID` | App Store Connect issuer ID |

The workflow does not need Apple ID passwords or provisioning profiles because it uses Developer ID signing and an App Store Connect API key for notarization.

## Architecture

```text
Pendant BLE ──> raw page vault ──> parser/session assembly ──> packet stream/WAV
                                                               └─> durable library/search

Mac system/app audio + microphone ──> recoverable CAF segments ──> durable library

WAV/audio ──> local whisper.cpp process ──> timestamped transcript ──> local search
                                                        └─> optional configured LLM
```

Key modules:

- `Sources/PendantKit` — BLE protocol, vault, parsing, Opus/WAV, library, transcription, optional provider client.
- `Sources/Domain` — durable recording, transcript, library, transcription, and provider models.
- `Sources/LessLimitlessApp` — SwiftUI shell, Mac capture service, Record and Library views.
- `Tests` — protocol, storage, decode, export, search, transcription, and provider tests.

## Current limitations

- Mac capture tracks are registered in the library after a successful stop, but capture segments are not yet merged into a single playback/transcription asset.
- The app has no model downloader or transcription job UI yet; local executable/model and optional-provider credentials can be configured in Settings, with API keys stored in Keychain.
- Pendant session export and Mac capture are not yet unified into a playback/detail screen.
- macOS hardware validation, Developer ID credentials, notarization execution, updater, and a production release DMG still need to be performed on a Mac.
- Raw Opus bytes without explicit packet boundaries are deliberately not decoded; guessing packet boundaries can silently corrupt audio.

## Contributing

Please keep new features local-first and non-destructive. Do not add Limitless endpoint calls. Add tests for protocol, storage, or processing changes, and run:

```sh
swift test
```

See [`docs/PRODUCT_SPEC.md`](docs/PRODUCT_SPEC.md) for the architecture and longer-term roadmap.

## License

This repository does not currently include a release license. Review the reverse-engineered protocol provenance in [`docs/PRODUCT_SPEC.md`](docs/PRODUCT_SPEC.md) before redistribution or commercial use.
