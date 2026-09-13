# Local Pendant for macOS — Product & Architecture Specification

**Status:** Draft v0.1  
**Target:** macOS 14+  
**Principle:** The app never calls Limitless APIs or web endpoints. Pendant access is direct over Bluetooth Low Energy.

## 1. Product vision

A private, local-first Mac app that turns a Limitless Pendant and Mac meeting audio into a searchable personal memory library. It directly syncs recordings from the pendant, captures selected Mac app/system audio and microphone input, transcribes audio on-device, and optionally sends user-selected text to a user-configured LLM.

The app must remain useful with no account, no subscription, and no network connection.

## 2. Product principles

1. **Local by default:** Audio, transcripts, search indexes, and metadata stay on the Mac.
2. **No Limitless endpoints:** No Limitless authentication, ingestion, lifelog, or other HTTP APIs.
3. **Safe sync:** Never delete or acknowledge pendant data until a durable, validated local copy exists.
4. **Transparent processing:** Every record shows its source, transcription model, processing state, and whether data left the Mac.
5. **Portable data:** Users can export audio, Markdown, JSON, and SRT/VTT without proprietary lock-in.
6. **Progressive capability:** BLE sync and playback work without transcription; transcription works without an LLM.
7. **Explicit consent:** Recording controls and indicators must make capture obvious. The app should remind users to follow local consent laws.

## 3. MVP scope

### 3.1 Pendant

- Discover, pair, remember, connect, and auto-reconnect to one pendant.
- Display connection state, battery, firmware, recording state, and storage usage.
- Synchronize stored pendant recordings over BLE.
- Decode pendant Opus audio locally and save a standard playable file.
- Persist a transactional sync ledger so interrupted transfers resume safely.
- Group nearby recording sessions into encounters.
- Allow manual erase only after a clear confirmation and local-copy verification.
- Do not automatically erase all storage.

### 3.2 Mac meeting capture

- Capture audio from a selected app using ScreenCaptureKit.
- Optionally capture and mix a selected microphone using AVAudioEngine.
- Show live level meters and an unambiguous recording indicator.
- Save audio continuously in crash-tolerant segments and finalize to a standard format.
- Support pause, resume, stop, and recovery of an interrupted recording.
- Record source metadata such as selected app, start/end time, and devices.

### 3.3 Local transcription

- Transcribe locally using a replaceable engine adapter, initially whisper.cpp.
- Offer model download/selection with size, speed, language, and disk-use details.
- Queue jobs and expose progress, cancellation, retry, and error states.
- Store timestamped transcript segments and detected language.
- Do not require an LLM for titles, playback, editing, or search.

### 3.4 Optional LLM processing

- Optional providers:
  - Local OpenAI-compatible endpoint, such as Ollama or LM Studio.
  - User-configured HTTPS OpenAI-compatible endpoint.
- Never configure or call a Limitless endpoint.
- Send transcript text only after an explicit per-provider disclosure and opt-in.
- Generate a title, summary, topics, decisions, and action items.
- Store provider/model/prompt version provenance on every generated artifact.
- Keep provider credentials in macOS Keychain.

### 3.5 Library and search

- Timeline/library combining pendant encounters and Mac recordings.
- Full-text search across transcript, title, notes, people, and generated content.
- Detail view with waveform/scrubber, transcript-following playback, editable title and notes.
- Filters for date, source, transcription state, tags, and people.
- Export original/normalized audio, Markdown, JSON, SRT, and VTT.
- Delete with clear scope: database record, generated artifacts, and audio files.

## 4. Explicit non-goals for MVP

- Limitless account sign-in or any Limitless API integration.
- iPhone/iPad clients or cross-device synchronization.
- Multiple simultaneous pendants.
- Speaker recognition/voiceprints.
- Semantic/vector search.
- Calendar, Slack, Linear, or task-manager integrations.
- Automatic recording based on calendar events.
- Live captions.
- Remote start/stop recording on the pendant; firmware support is unreliable.
- Decrypting historical recordings encrypted to Limitless's server key.

## 5. Recommended user experience

### 5.1 App structure

Use a normal SwiftUI app with an optional menu-bar companion.

- **Library:** timeline, search, filters, processing states.
- **Record:** app/system source, microphone, gain meters, timer, start/stop.
- **Pendant:** device card, battery/storage, sync progress, safe cleanup.
- **Tasks:** action items extracted by an optional LLM.
- **Settings:** storage, transcription model, LLM providers, privacy, exports.

The menu-bar item should show recording/connection state and provide fast record, stop, sync, and open-library actions.

### 5.2 First-run flow

1. Explain local-first behavior and the no-Limitless-endpoint guarantee.
2. Let the user choose either **Connect Pendant**, **Set up Mac capture**, or **Continue without setup**.
3. Request Bluetooth only when pendant setup starts.
4. Request Screen Recording and Microphone only when capture setup starts.
5. Offer a local transcription model download; permit skipping it.
6. Keep LLM setup optional and separate.

## 6. Technical architecture

### 6.1 Technology choices

- Swift 5.9+ and SwiftUI on macOS 14+.
- AppKit only for menu-bar/window integration where SwiftUI is insufficient.
- CoreBluetooth for pendant communication.
- ScreenCaptureKit for per-app/system audio.
- AVAudioEngine/Core Audio for microphone input and conversion.
- AVFoundation for local audio files.
- libopus for pendant frame decoding.
- SQLite with FTS5 for durable metadata, sync state, jobs, and full-text search.
- whisper.cpp behind a local transcription protocol.
- Security/Keychain for provider credentials.
- Unified Logging with private/redacted fields.

Use an Xcode project for shipping, signing, sandbox settings, tests, and resources. Internal modules may be Swift packages.

### 6.2 Module boundaries

```text
LocalPendantApp
├── AppShell             SwiftUI navigation, commands, menu bar
├── Domain               Recording, Transcript, Encounter, Job models
├── PendantKit
│   ├── BLETransport     CoreBluetooth state machine
│   ├── PendantWire      protobuf/framing and command correlation
│   ├── PendantSync      durable page ledger and safe ACK policy
│   └── OpusDecode       raw pendant Opus → PCM
├── CaptureKit
│   ├── SystemCapture    ScreenCaptureKit
│   ├── Microphone       AVAudioEngine
│   └── AudioPipeline    resample, mix, meter, segmented writer
├── TranscriptionKit     engine protocol + whisper.cpp adapter
├── IntelligenceKit      optional local/remote LLM adapters
├── Persistence          SQLite/FTS, migrations, file store
├── Playback             AVFoundation playback and transcript sync
├── Export               audio/Markdown/JSON/SRT/VTT
└── Security             Keychain, endpoint policy, privacy ledger
```

Dependencies point inward: UI depends on application services and domain protocols; device, model, storage, and provider implementations remain replaceable.

### 6.3 Core service protocols

```swift
protocol PendantTransport {
    var events: AsyncStream<PendantEvent> { get }
    func scan() async throws -> [PendantCandidate]
    func connect(to id: UUID) async throws
    func disconnect() async
    func send(_ command: PendantCommand) async throws -> PendantResponse?
}

protocol RecordingSyncService {
    func inspectDevice() async throws -> PendantSnapshot
    func sync() -> AsyncThrowingStream<SyncProgress, Error>
    func verifyLocalCopy(recordingID: RecordingID) async throws -> VerificationResult
    func eraseVerifiedPages() async throws
}

protocol AudioCaptureService {
    func availableSources() async throws -> [CaptureSource]
    func start(configuration: CaptureConfiguration) async throws -> RecordingID
    func pause() async throws
    func resume() async throws
    func stop() async throws -> RecordingID
}

protocol TranscriptionEngine {
    var capabilities: TranscriptionCapabilities { get }
    func transcribe(_ request: TranscriptionRequest) -> AsyncThrowingStream<TranscriptionProgress, Error>
}

protocol IntelligenceProvider {
    var locality: ProcessingLocality { get }
    func generateArtifacts(for transcript: Transcript, options: GenerationOptions) async throws -> GeneratedArtifacts
}
```

## 7. Pendant protocol implementation

The protocol was reverse-engineered from the Android app and is not an official stable API. Isolate it behind tests and version-tolerant parsers.

### 7.1 BLE services

- Audio service: `632DE001-604C-446B-A80F-7963E950F3FB`
- Control characteristic: `632DE002-604C-446B-A80F-7963E950F3FB`
- Data notification characteristic: `632DE003-604C-446B-A80F-7963E950F3FB`
- Standard battery service/level: `180F` / `2A19`

Discover by service and name, but connect only to a user-selected, remembered `CBPeripheral.identifier`. Do not rely on a MAC address, which CoreBluetooth does not expose.

### 7.2 Pairing and connection

- Initialize `CBCentralManager` only after the user opts into pendant support.
- Retain the selected peripheral identifier and use state restoration/retrieval for reconnects.
- Subscribe to data notifications before issuing commands.
- Trigger macOS bonding by writing the encrypted TimeSync/control characteristic.
- Do not invent an application authentication handshake without captured evidence.
- Respect CoreBluetooth's `maximumWriteValueLength` and backpressure callbacks.

### 7.3 Message framing

Messages are protobuf payloads wrapped by an envelope containing message index, fragment sequence, fragment count, and payload bytes.

The implementation must:

- Generate or rigorously test protobuf codecs.
- Increment outbound message IDs safely.
- Fragment outbound messages based on actual maximum write size.
- Reassemble inbound fragments by message ID and sequence.
- Reject impossible fragment counts and oversized payloads.
- Detect duplicates, expire incomplete messages, and cap memory usage.
- Correlate request IDs with responses and enforce command timeouts.
- Preserve unknown protobuf fields for forward compatibility where feasible.

### 7.4 Sync flow

1. Connect and subscribe.
2. Read device identity, battery, storage, and recording status.
3. Send current time and confirm response.
4. Request batch flash-page download.
5. For each page:
   - Validate envelope and protobuf structure.
   - Record device ID, session, run, sequence, page index, timestamps, flags, and error state.
   - Persist raw page bytes atomically.
   - Mark the page `received`, never `acknowledged` yet.
6. Determine completion by a conservative idle timeout plus storage/status reconciliation. The reference CLI's fixed 120-second wait is not sufficient.
7. Assemble sessions using firmware start/stop flags with timestamp-gap fallback.
8. Decode Opus to PCM and write crash-safe audio segments.
9. Finalize audio and calculate SHA-256 hashes for raw pages and output audio.
10. Commit recording metadata, page mappings, and verification state in one database transaction.
11. Only then make pages eligible for acknowledgement/deletion.
12. Keep an audit trail of every acknowledgement and cleanup action.

If firmware does not provide a proven per-page ACK/delete behavior, retain pages on-device and expose only explicit whole-storage cleanup after verified sync. Never infer destructive semantics from an undocumented message.

### 7.5 Audio details

- Common codec: raw Opus, 16 kHz, mono.
- Frames lack an Ogg container and may lack explicit length prefixes.
- Chunks may carry audio plus status fields; `Chunk` is not a `oneof`.
- Respect `did_start_recording` and `did_stop_recording` flags.
- Preserve original page data so decoding can be improved later.
- Existing encrypted recordings using Limitless's public key cannot be recovered locally.
- User-owned key injection is experimental and should be a post-MVP, advanced feature after cryptographic behavior is verified.

## 8. Mac audio capture design

### 8.1 Sources

- Use `SCShareableContent` to list applications and displays.
- Prefer per-application capture for clear consent and lower noise.
- Exclude this app's own process/audio.
- Capture microphone separately through AVAudioEngine.
- Resample both paths into a common 16-kHz mono float/PCM format for transcription.

### 8.2 Reliability

- Keep capture callbacks free of database, network, and heavy model work.
- Feed bounded actor-owned buffers; expose overruns as visible errors rather than silently dropping audio.
- Write short recoverable segments, then finalize/merge when recording stops.
- Save recording state and segment manifests frequently enough to recover after a crash.
- Handle source termination, device changes, sleep/wake, permission revocation, and disk-full conditions.

## 9. Persistence model

Use SQLite in `~/Library/Application Support/<AppName>/Library.sqlite` and media files under a stable `Media/` hierarchy. Enable WAL mode and migrations. Store secrets only in Keychain.

### 9.1 Main entities

- `device`: stable CoreBluetooth ID, serial, firmware, last seen.
- `recording`: ID, source, start/end, status, audio paths, hashes, device ID.
- `audio_segment`: recording ID, order, path, duration, hash, finalized state.
- `pendant_page`: device/session/run/page/sequence identity, raw path/hash, receive/verify/ACK states.
- `transcript`: recording ID, engine/model/language, version, status.
- `transcript_segment`: transcript ID, start/end, text, optional speaker.
- `encounter`: grouped recording IDs and date range.
- `note` and `tag`.
- `generated_artifact`: type, provider, model, prompt version, content, locality.
- `action_item`: text, owner, due date, completion state, source artifact.
- `job`: kind, input, state, progress, attempts, error, timestamps.
- `privacy_event`: provider disclosure/consent and external processing audit.

Use uniqueness constraints for pendant page identity and content hashes to make sync idempotent.

### 9.2 File protection

- Rely on FileVault as the baseline and clearly state this in settings.
- Use atomic writes and restrictive file permissions.
- Offer an optional encrypted-library mode after MVP; do not market plaintext local storage as encrypted.
- Ensure deletion removes every referenced original, derived, cache, and export file.

## 10. Processing pipeline

```text
Pendant BLE pages ─→ raw page vault ─→ Opus decode ─┐
                                                    ├→ normalized audio
Mac app + mic ─→ resample/mix ─→ segmented writer ─┘
                  ↓
             local ASR job
                  ↓
       transcript segments + FTS
                  ↓ optional, explicit
       local or configured LLM
                  ↓
 summary / decisions / tasks / topics
```

Every stage is resumable and represented by a durable job. A failed later stage never invalidates safely stored audio.

## 11. Local transcription

Initial engine: whisper.cpp wrapped through a narrow C/Swift bridge.

Requirements:

- Model manager verifies downloaded model checksums.
- User chooses model and can delete models independently of recordings.
- Chunk long audio with overlap and reconcile timestamps.
- Use Voice Activity Detection to skip silence where reliable.
- Preserve engine/model/version and options for reproducibility.
- Support English first while retaining language fields and an upgrade path.
- Run at a utility/background priority and pause under thermal pressure if appropriate.

Speaker diarization is not an MVP promise. Keep optional speaker labels in the schema for future engines.

## 12. Optional LLM policy

- Local OpenAI-compatible endpoints may use HTTP only for loopback hosts.
- Non-loopback providers must use HTTPS.
- Validate URL scheme/host; do not force-unwrap URLs.
- Store bearer tokens in Keychain.
- Show exactly what content will be sent and whether audio is ever included. MVP sends text only.
- Make each generation action explicit by default; an automation toggle may be added later.
- Redact transcript content and tokens from logs.
- Block known Limitless domains and do not ship a Limitless provider adapter.

## 13. Security and privacy requirements

- App Sandbox enabled unless a documented capability makes it impossible.
- Hardened runtime and library validation enabled for release builds.
- Sign and notarize distributions.
- Bluetooth, microphone, and screen-capture purpose strings must be specific.
- No analytics, telemetry, crash upload, or remote logging by default.
- No plaintext provider keys.
- No full BLE payloads, transcript text, or audio bytes in production logs.
- Remember and allowlist the user-selected peripheral identifier.
- Treat all BLE/protobuf lengths as hostile input.
- Maintain a visible external-processing history.
- Provide a privacy report listing on-disk locations and configured endpoints.

## 14. Testing strategy

### 14.1 Protocol tests

- Golden protobuf command/response fixtures from known captures.
- Fragmentation/reassembly: one/many fragments, out of order, duplicates, missing fragments, invalid counts, oversized payloads, and index wrap.
- Unknown fields and firmware variants.
- Transfer gaps, duplicate pages, page errors, disconnect/resume, and idempotency.
- Ensure no ACK/delete is emitted before transactional verification.
- Fuzz wire and flash-page parsers.

### 14.2 Audio tests

- Golden Opus fixtures covering observed codec modes and frame durations.
- PCM duration, sample rate, channel count, and deterministic hash checks.
- Mixed source gain/clipping and buffer-overrun tests.
- Crash recovery and disk-full simulations.

### 14.3 App tests

- SQLite migration and FTS tests.
- Job restart/retry tests.
- Mock CoreBluetooth transport state-machine tests.
- Provider URL policy and Keychain tests.
- UI tests for permission denial, offline use, destructive cleanup, and exports.
- Manual hardware matrix across supported macOS versions and known pendant firmware.

## 15. Delivery phases

### Phase 0 — Protocol fixture harness

- Establish repository, Xcode project, CI, formatting, and test targets.
- Implement wire types and fixture-based parser tests.
- Capture sanitized hardware traces from an owned pendant.
- Prove pairing, status, page download, Opus decode, and disconnect recovery.

**Exit:** A command-line/debug harness can download without data loss and decode a short known recording.

### Phase 1 — Safe pendant library

- SwiftUI shell, permissions, pairing, remembered device, status, sync progress.
- SQLite schema and durable page ledger.
- Playback, encounter grouping, raw/standard audio export.

**Exit:** Repeated/interrupted sync is idempotent; no pendant data is removed automatically.

### Phase 2 — Mac capture

- Per-app/system capture, microphone mix, meters, segmented writer, recovery.
- Unified library and source metadata.

**Exit:** A one-hour recording survives normal source changes and can be played/exported.

### Phase 3 — Local transcription and search

- whisper.cpp model manager and job queue.
- Timestamped transcript, editing, FTS5, transcript-following playback.

**Exit:** The complete flow works offline with no account or endpoint configuration.

### Phase 4 — Optional intelligence

- Local and user-configured OpenAI-compatible providers.
- Summaries, decisions, topics, and action items with provenance/privacy UI.

**Exit:** Local LLM flow works; remote flow requires informed opt-in and passes endpoint/security tests.

### Phase 5 — Release hardening

- Hardware/firmware compatibility matrix, accessibility, performance, privacy report.
- Sandboxing, signing, notarization, updater strategy, and license notices.

## 16. MVP acceptance criteria

1. Network inspection confirms the app works offline and never contacts a Limitless domain.
2. A selected pendant pairs through macOS and reconnects by remembered identifier.
3. Interrupted sync resumes without duplicate records or premature deletion.
4. A downloaded recording is playable and its local copy is hash-verified.
5. Mac app audio and optional microphone can be captured with visible status and no silent buffer drops.
6. Both pendant and Mac recordings can be transcribed locally.
7. Search finds transcript body text, titles, notes, tags, and generated content.
8. The app remains fully useful when no LLM provider is configured.
9. Remote text processing is explicit, HTTPS-only except loopback, and credentials are in Keychain.
10. Deleting a recording removes all associated local files and index entries.
11. Production logs contain no transcript, audio payload, BLE payload, or credentials.
12. Export produces usable audio, Markdown/JSON, and SRT/VTT files.

## 17. Feature roadmap

### High-value next features

- Calendar-aware meeting naming without auto-recording by default.
- Live captions in a compact always-on-top window.
- Obsidian/Markdown folder export with stable links.
- Local semantic search and “ask my history” with citations to transcript timestamps.
- Better encounter grouping using time, device state, and topic continuity.
- User-defined local automations, such as tagging meetings by source app.
- Multi-language transcription and translation.
- Speaker labeling and opt-in local voice profiles.
- Retention policies by source/tag and automatic verified pendant cleanup.
- Encrypted backup/export archive.

### Useful small features

- Global hotkey for Mac recording.
- “Copy last five minutes” transcript action.
- Bookmarks during recording or pendant playback.
- Silence trimming and playback speed controls.
- Status notifications for low pendant battery, full storage, sync completion, and failed jobs.
- Duplicate detection for imported audio.
- Health view for model disk usage, media storage, and pending sync pages.

## 18. Source learnings and provenance

This architecture is informed by:

- `sdelcore/pendant-cli` at commit `1c7165976d1113707f5b73550510ee5ddfd6a89b`, especially its reverse-engineered GATT UUIDs, protobuf schema, flash-page layout, and raw Opus findings. Its code is described as personal/research use only, so protocol knowledge should be independently validated and its code should not be copied into a commercial product without legal review.
- `ArgentAIOS/xoome` at commit `5017df78d905efa769cc8b694f4a93a4d52cccae`, an MIT native Swift example demonstrating CoreBluetooth, ScreenCaptureKit, AVAudioEngine, and libopus integration. Its prototype patterns are useful, but its plaintext secrets, non-durable sync ledger, heuristic parser, and early destructive ACK behavior must not be inherited.
- BasedHardware/Omi protocol lineage referenced by XooMe. Verify upstream licenses and provenance before reusing code or generated definitions.

Reverse-engineered protocol compatibility and product distribution should receive legal review. The product must not imply affiliation with or endorsement by Limitless.

## 19. Open decisions before implementation

- Product name and bundle identifier.
- Minimum hardware/firmware versions available for testing.
- Whether app audio capture means selected-app only or also whole-system mode in MVP.
- Default whisper.cpp model and distribution/download approach.
- Audio archival format: original/raw + M4A, or original/raw + FLAC.
- Whether initial release is direct-download/notarized only or Mac App Store targeted.
- Whether remote LLM support ships in MVP or immediately after the offline core.
