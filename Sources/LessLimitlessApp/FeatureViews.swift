import PendantKit
import Domain
import Foundation
import SwiftUI

struct LibraryView: View {
    @State private var query = ""

    private var recordings: [Recording] {
        guard !query.isEmpty else { return SampleData.recordings }
        return SampleData.recordings.filter {
            $0.title.localizedCaseInsensitiveContains(query) ||
            $0.tags.contains { $0.localizedCaseInsensitiveContains(query) }
        }
    }

    var body: some View {
        List {
            Section {
                ForEach(recordings) { recording in
                    RecordingRow(recording: recording)
                }
            } header: {
                Text("Recent recordings")
            }
        }
        .overlay {
            if recordings.isEmpty {
                ContentUnavailableView.search(text: query)
            }
        }
        .searchable(text: $query, prompt: "Search sample library")
        .navigationTitle("Library")
        .toolbar {
            ToolbarItem {
                Button("Import", systemImage: "square.and.arrow.down") {}
                    .disabled(true)
                    .help("Import is not implemented in this preview")
            }
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
    @State private var includeMicrophone = true
    @State private var source = "Choose an application…"

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                FeatureHeader(symbol: "record.circle", title: "Record on this Mac", subtitle: "Capture setup preview — no audio is being recorded.")
                GroupBox("Capture source") {
                    VStack(alignment: .leading, spacing: 14) {
                        Picker("Application", selection: $source) {
                            Text("Choose an application…").tag("Choose an application…")
                        }
                        Toggle("Include microphone", isOn: $includeMicrophone)
                        Divider()
                        HStack {
                            Label("System audio", systemImage: "speaker.wave.2")
                            Spacer()
                            Text("Not configured").foregroundStyle(.secondary)
                        }
                        HStack {
                            Label("Microphone", systemImage: "mic")
                            Spacer()
                            Text("Permission not requested").foregroundStyle(.secondary)
                        }
                    }.padding(8)
                }
                Button("Start Recording", systemImage: "record.circle.fill") {}
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .tint(.red)
                    .disabled(true)
                Text("Capture controls will become available when the local capture service is implemented.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: 620)
            .padding(36)
        }
        .navigationTitle("Record")
    }
}

struct PendantView: View {
    @EnvironmentObject private var client: PendantClient

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
                        Button("Refresh Status") { client.requestDeviceStatus() }
                        Button("Disconnect") { client.disconnect() }
                    } else {
                        Button("Scan Again") { client.scan() }.buttonStyle(.borderedProminent)
                            .disabled(client.state == .connecting || client.state == .discoveringServices)
                        Button("Disable Bluetooth") { client.disable() }
                    }
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
    @State private var transcriptionEnabled = false
    @State private var externalProcessing = false

    var body: some View {
        Form {
            Section("Privacy") {
                LabeledContent("Data location", value: "On this Mac (planned)")
                LabeledContent("Network access", value: "None configured")
                Toggle("Allow external text processing", isOn: $externalProcessing).disabled(true)
                Text("No analytics, provider, or network integration is included in this shell.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Transcription") {
                Toggle("Local transcription", isOn: $transcriptionEnabled).disabled(true)
                LabeledContent("Model", value: "No model installed")
            }
            Section("Storage") {
                LabeledContent("Library", value: "Not initialized")
                Text("Local files would rely on FileVault; this preview does not claim application-level encryption.")
                    .font(.caption).foregroundStyle(.secondary)
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

private extension TimeInterval {
    var formattedDuration: String {
        let totalSeconds = max(0, Int(self))
        let hours = totalSeconds / 3_600
        let minutes = (totalSeconds % 3_600) / 60
        let seconds = totalSeconds % 60
        return String(format: "%d:%02d:%02d", hours, minutes, seconds)
    }
}
