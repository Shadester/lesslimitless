import PendantKit
import Domain
import Foundation
import SwiftUI

struct LibraryView: View {
    @EnvironmentObject private var library: LibraryController
    @EnvironmentObject private var settings: AppSettingsController
    @State private var query = ""

    private var recordings: [LibraryRecording] {
        query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? library.recordings
            : library.searchResults.map(\.recording)
    }

    var body: some View {
        NavigationStack {
            List {
                Section("Local recordings") {
                    ForEach(recordings) { recording in
                        NavigationLink { LibraryDetailView(recording: recording) } label: {
                            LibraryRecordingRow(recording: recording)
                        }
                    }
                }
            }
            .overlay {
                if recordings.isEmpty {
                    ContentUnavailableView(
                        query.isEmpty ? "No local recordings" : "No matching recordings",
                        systemImage: query.isEmpty ? "waveform" : "magnifyingglass",
                        description: Text(library.errorMessage ?? "Record Mac audio or sync a pendant to build your local library.")
                    )
                }
            }
            .searchable(text: $query, prompt: "Search transcript, notes, tags, and summaries")
            .onChange(of: query) { _, value in Task { await library.search(value) } }
            .task {
                await library.reload()
                await library.processPendingTranscriptions(job: settings.transcriptionJobTemplate, summaryConfiguration: settings.autoSummarize ? settings.llmConfiguration : nil)
            }
            .navigationTitle("Library")
            .toolbar {
                ToolbarItem { Button("Refresh", systemImage: "arrow.clockwise") { Task { await library.reload() } } }
            }
        }
    }
}

private struct LibraryRecordingRow: View {
    @EnvironmentObject private var library: LibraryController
    let recording: LibraryRecording

    private var isTranscribing: Bool { library.transcribingID == recording.id }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: sourceSymbol).foregroundStyle(Color.accentColor).frame(width: 26)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(recording.title).font(.headline)
                    if isTranscribing { ProgressView().controlSize(.small) }
                }
                if let preview = recording.semanticPreview {
                    Text(preview).font(.subheadline).foregroundStyle(.primary).lineLimit(2)
                } else {
                    Text(statusText)
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                HStack(spacing: 6) {
                    Text(recording.source.displayName)
                    Text("·")
                    Text(recording.startedAt.formatted(date: .abbreviated, time: .shortened))
                    if let duration = recording.duration {
                        Text("·")
                        Text(duration.formattedDuration)
                    }
                    ForEach(recording.tags, id: \.self) { Text($0).padding(.horizontal, 5).background(.quaternary, in: Capsule()) }
                }.font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }.padding(.vertical, 6)
    }

    /// `.ready` with no transcript segments means transcription ran and found no
    /// speech, not that it's still in progress — show that distinctly so it doesn't
    /// read as a stray processing-state word sitting where content would be.
    private var statusText: String {
        switch recording.processingState {
        case .ready: "No speech detected"
        default: recording.processingState.rawValue.capitalized
        }
    }

    private var sourceSymbol: String {
        switch recording.source {
        case .pendant: "wave.3.right"
        case .macApplication, .systemAudio: "macwindow"
        case .imported: "arrow.down.doc"
        }
    }
}

private struct RecordingRow: View {
    let recording: Recording

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: sourceSymbol)
                .font(.title2)
                .foregroundStyle(Color.accentColor)
                .frame(width: 34, height: 34)
                .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text(recording.title).font(.headline)
                    StatusBadge(status: recording.status)
                }
                Text(recording.source.displayName)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    Text(recording.startedAt, style: .relative)
                    Text("·")
                    Text(recording.duration.formattedDuration)
                    ForEach(recording.tags, id: \.self) { tag in
                        Text(tag).padding(.horizontal, 6).padding(.vertical, 2)
                            .background(.quaternary, in: Capsule())
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "chevron.right").foregroundStyle(.tertiary)
        }
        .padding(.vertical, 7)
    }

    private var sourceSymbol: String {
        switch recording.source {
        case .pendant: "wave.3.right"
        case .macApplication, .systemAudio: "macwindow"
        case .imported: "arrow.down.doc"
        }
    }
}

private struct StatusBadge: View {
    let status: RecordingStatus

    var body: some View {
        if status != .ready {
            Text(status.rawValue.capitalized)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(status == .failed ? Color.red : Color.orange)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(.quaternary, in: Capsule())
        }
    }
}

struct RecordView: View {
    @EnvironmentObject private var library: LibraryController
    @StateObject private var capture = MacAudioCaptureService()
    @State private var selectedApplication: MacAudioCaptureApplication?
    @State private var captureSystemAudio = true
    @State private var includeMicrophone = false

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                FeatureHeader(
                    symbol: capture.state == .recording ? "record.circle.fill" : "record.circle",
                    title: capture.state == .recording ? "Recording on this Mac" : "Record on this Mac",
                    subtitle: capture.errorMessage ?? statusText
                )
                GroupBox("Capture source") {
                    VStack(alignment: .leading, spacing: 14) {
                        Picker("Source", selection: $captureSystemAudio) {
                            Text("System audio").tag(true)
                            Text("One application").tag(false)
                        }.pickerStyle(.segmented)
                        if !captureSystemAudio {
                            Picker("Application", selection: $selectedApplication) {
                                Text("Choose an application…").tag(MacAudioCaptureApplication?.none)
                                ForEach(capture.eligibleApplications) { application in
                                    Text(application.name).tag(MacAudioCaptureApplication?.some(application))
                                }
                            }
                        }
                        Toggle("Include microphone", isOn: $includeMicrophone)
                        Divider()
                        LevelRow(label: "System audio", value: capture.systemAudioLevel)
                        if includeMicrophone { LevelRow(label: "Microphone", value: capture.microphoneLevel) }
                    }.padding(8)
                }
                HStack {
                    if capture.state == .recording {
                        Button("Stop Recording", systemImage: "stop.circle.fill") { Task { await capture.stop() } }
                            .buttonStyle(.borderedProminent).tint(.red).controlSize(.large)
                    } else {
                        Button("Start Recording", systemImage: "record.circle.fill") { startCapture() }
                            .buttonStyle(.borderedProminent).tint(.red).controlSize(.large)
                            .disabled(!captureSystemAudio && selectedApplication == nil)
                        Button("Refresh Applications") { Task { await capture.refreshEligibleApplications() } }
                    }
                }
                Text("Audio is written locally in recoverable CAF segments with a manifest. Capture requires Screen Recording permission; microphone permission is requested only when enabled.")
                    .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            .frame(maxWidth: 620)
            .padding(36)
        }
        .navigationTitle("Record")
        .task { await capture.refreshEligibleApplications() }
        .onAppear {
            capture.onRecordingFinished = { directory, request in
                Task { await library.registerCapture(directory: directory, request: request) }
            }
        }
    }

    private var statusText: String {
        switch capture.state {
        case .idle: "Preparing capture"
        case .requestingPermission: "Requesting permission"
        case .ready: "Ready to record locally"
        case .recording: "Recording locally"
        case .stopped: "Recording saved locally"
        case .failed: "Capture needs attention"
        }
    }

    private func startCapture() {
        let source: MacAudioCaptureSource = captureSystemAudio
            ? .systemAudio
            : .application(selectedApplication!)
        let request = MacAudioCaptureRequest(source: source, includeMicrophone: includeMicrophone)
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LessLimitless", isDirectory: true)
            .appendingPathComponent("MacCapture", isDirectory: true)
        Task { await capture.start(request: request, under: root) }
    }
}

private struct LevelRow: View {
    let label: String
    let value: Float
    var body: some View {
        HStack {
            Text(label).frame(width: 100, alignment: .leading)
            ProgressView(value: Double(value)).tint(.accentColor)
            Text("\(Int(value * 100))%").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
        }
    }
}

struct PendantView: View {
    @EnvironmentObject private var client: PendantClient
    @EnvironmentObject private var library: LibraryController
    @EnvironmentObject private var settings: AppSettingsController
    @State private var isSyncingToLibrary = false
    @State private var syncStatusText: String?

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                FeatureHeader(
                    symbol: "wave.3.right.circle",
                    title: client.connectedName ?? title,
                    subtitle: client.lastEvent
                )

                GroupBox {
                    VStack(spacing: 16) {
                        DetailLine(label: "Connection", value: stateLabel)
                        DetailLine(label: "Battery", value: client.batteryPercent.map { "\($0)%" } ?? "—")
                        DetailLine(label: "Durably stored pages", value: "\(client.storedPageCount)")
                        if client.state == .ready {
                            DetailLine(label: "Sync status", value: client.isSyncIdle ? "Looks complete (no new pages recently)" : "Receiving pages…")
                        }
                        Divider()
                        Label("Read-only sync never acknowledges or erases pendant pages.", systemImage: "externaldrive.badge.checkmark")
                            .foregroundStyle(.secondary)
                    }.padding(8)
                } label: {
                    Label("Device", systemImage: "sensor")
                }

                if !client.candidates.isEmpty, client.state != .ready {
                    GroupBox("Nearby pendants") {
                        VStack(spacing: 8) {
                            ForEach(client.candidates) { candidate in
                                HStack {
                                    VStack(alignment: .leading) {
                                        Text(candidate.name).fontWeight(.medium)
                                        Text(candidate.id.uuidString).font(.caption2).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Text(candidate.rssi == 0 ? "Remembered" : "\(candidate.rssi) dBm")
                                        .font(.caption).foregroundStyle(.secondary)
                                    Button("Connect") { client.connect(to: candidate.id) }
                                        .disabled(client.state == .connecting || client.state == .discoveringServices)
                                }
                                .padding(.vertical, 4)
                            }
                        }.padding(8)
                    }
                }

                HStack {
                    if client.state == .disabled {
                        Button("Enable Bluetooth") { client.enable() }.buttonStyle(.borderedProminent)
                    } else if client.state == .ready {
                        Button("Read Stored Pages") { client.requestStoredPages() }.buttonStyle(.borderedProminent)
                        Button("Sync to Library") {
                            isSyncingToLibrary = true
                            syncStatusText = nil
                            Task {
                                let imported = await library.syncPendant(deviceName: client.connectedName ?? "Pendant")
                                if let error = library.errorMessage {
                                    syncStatusText = error
                                } else {
                                    syncStatusText = imported > 0 ? "Synced \(imported) new recording(s)." : "No new recordings to sync."
                                }
                                isSyncingToLibrary = false
                                await library.processPendingTranscriptions(job: settings.transcriptionJobTemplate, summaryConfiguration: settings.autoSummarize ? settings.llmConfiguration : nil)
                            }
                        }.disabled(isSyncingToLibrary)
                        Button("Refresh Status") { client.requestDeviceStatus() }
                        Button("Disconnect") { client.disconnect() }
                    } else {
                        Button("Scan Again") { client.scan() }.buttonStyle(.borderedProminent)
                            .disabled(client.state == .connecting || client.state == .discoveringServices)
                        Button("Disable Bluetooth") { client.disable() }
                    }
                }

                if let syncStatusText {
                    Text(syncStatusText).font(.caption).foregroundStyle(.secondary)
                }

                Text(client.pageVaultError ?? "Storage pages are written atomically to the local vault before any future decoding. This app still never acknowledges or erases pendant data.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: 620)
            .padding(36)
        }
        .navigationTitle("Pendant")
    }

    private var title: String {
        switch client.state {
        case .ready: "Pendant connected"
        case .scanning: "Looking for your pendant"
        case .connecting, .discoveringServices: "Connecting"
        default: "No pendant connected"
        }
    }

    private var stateLabel: String {
        client.state.rawValue.replacingOccurrences(of: "([a-z])([A-Z])", with: "$1 $2", options: .regularExpression).capitalized
    }
}

struct TasksView: View {
    var body: some View {
        List(SampleData.tasks) { task in
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: task.state == .completed ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(task.state == .completed ? Color.green : Color.secondary)
                VStack(alignment: .leading, spacing: 4) {
                    Text(task.text).strikethrough(task.state == .completed)
                    HStack {
                        if let owner = task.owner { Text(owner) }
                        if let dueDate = task.dueDate { Text(dueDate, style: .date) }
                    }.font(.caption).foregroundStyle(.secondary)
                }
            }.padding(.vertical, 5)
        }
        .navigationTitle("Tasks")
        .safeAreaInset(edge: .bottom) {
            Text("Sample tasks only. Optional local or user-configured intelligence is not connected.")
                .font(.caption).foregroundStyle(.secondary).padding(12)
                .frame(maxWidth: .infinity).background(.bar)
        }
    }
}

struct SettingsView: View {
    @EnvironmentObject private var settings: AppSettingsController

    var body: some View {
        Form {
            Section("Local transcription") {
                TextField("whisper.cpp executable", text: $settings.whisperExecutablePath)
                TextField("Model file", text: $settings.whisperModelPath)
                Text("A whisper.cpp executable and tiny English model ship with the app by default. Override with your own local build/model if you want a different language or accuracy tradeoff.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Optional text provider") {
                TextField("OpenAI-compatible endpoint", text: $settings.llmEndpoint)
                TextField("Model", text: $settings.llmModel)
                SecureField("API key (Keychain)", text: $settings.providerKeyDraft)
                Button("Save API Key in Keychain") { settings.saveProviderKey() }
                Text("Only transcript text is sent. HTTP is allowed only for localhost; remote endpoints must use HTTPS. Redirects and Limitless hosts are blocked.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Auto-summarize after transcription", isOn: $settings.autoSummarize)
                Text("Off by default. When on, every new recording's transcript is sent to the endpoint above as soon as it's transcribed.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Storage") {
                LabeledContent("Library", value: "Application Support/LessLimitless")
                Text("Files rely on FileVault until an encrypted-library mode is added.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let status = settings.statusMessage {
                Section { Text(status).foregroundStyle(.secondary) }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Settings")
    }
}

private struct FeatureHeader: View {
    let symbol: String
    let title: String
    let subtitle: String

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: symbol).font(.system(size: 50)).foregroundStyle(Color.accentColor)
            Text(title).font(.title.bold())
            Text(subtitle).multilineTextAlignment(.center).foregroundStyle(.secondary)
        }
    }
}

private struct DetailLine: View {
    let label: String
    let value: String
    var body: some View {
        HStack { Text(label); Spacer(); Text(value).foregroundStyle(.secondary) }
    }
}

extension TimeInterval {
    var formattedDuration: String {
        let totalSeconds = max(0, Int(self))
        let hours = totalSeconds / 3_600
        let minutes = (totalSeconds % 3_600) / 60
        let seconds = totalSeconds % 60
        return String(format: "%d:%02d:%02d", hours, minutes, seconds)
    }
}
