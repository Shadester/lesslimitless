import Domain
import SwiftUI

struct LibraryDetailView: View {
    @EnvironmentObject private var library: LibraryController
    @EnvironmentObject private var settings: AppSettingsController
    @Environment(\.dismiss) private var dismiss
    @State private var draft: LibraryRecording
    @State private var detailsExpanded = false
    @StateObject private var playback = LibraryPlaybackController()

    private var isWorking: Bool { library.transcribingID == draft.id }

    init(recording: LibraryRecording) {
        _draft = State(initialValue: recording)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                DisclosureGroup("Details", isExpanded: $detailsExpanded) { detailsBody }
                if let summary = latestSummary { summaryCard(summary) }
                transcriptBody
            }
            .padding()
        }
        .safeAreaInset(edge: .bottom) { playerBar }
        .navigationTitle(draft.title)
        .toolbar {
            ToolbarItemGroup {
                if isWorking { ProgressView().controlSize(.small) }
                Button("Transcribe") { transcribe() }.disabled(settings.transcriptionSource == nil || isWorking)
                Button("Summarize") { summarize() }.disabled(settings.llmConfiguration == nil || draft.transcriptSegments.isEmpty || isWorking)
                Button("Save") { Task { await library.save(draft) } }
                Button("Delete", role: .destructive) { Task { await library.delete(draft); dismiss() } }
            }
        }
        .task {
            if let url = await library.mediaURL(for: draft) { playback.load(url) }
        }
        .onDisappear { playback.stop() }
        .onReceive(library.$recordings) { recordings in
            if let updated = recordings.first(where: { $0.id == draft.id }) { draft = updated }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(draft.title).font(.largeTitle).bold()
            Text(metaLine).font(.subheadline).foregroundStyle(.secondary)
        }
    }

    private var metaLine: String {
        var parts = [draft.source.displayName]
        if let duration = draft.duration { parts.append(duration.formattedDuration) }
        parts.append(draft.startedAt.formatted(date: .abbreviated, time: .shortened))
        return parts.joined(separator: " · ")
    }

    private var detailsBody: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField("Title", text: $draft.title)
            TextField("Tags (comma-separated)", text: Binding(
                get: { draft.tags.joined(separator: ", ") },
                set: { draft.tags = $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }
            ))
            LabeledContent("State", value: draft.processingState.rawValue.capitalized)
            TextEditor(text: $draft.notes).frame(minHeight: 100)
        }
        .padding(.top, 8)
        .textFieldStyle(.roundedBorder)
    }

    private var latestSummary: LibraryGeneratedArtifact? {
        draft.generatedArtifacts.last(where: { $0.kind.hasPrefix("summary") })
    }

    private func summaryCard(_ summary: LibraryGeneratedArtifact) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Summary").font(.headline)
            Text(summary.text).textSelection(.enabled)
            Text(summary.kind).font(.caption).foregroundStyle(.secondary)
        }
        .padding()
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 12))
    }

    @ViewBuilder
    private var transcriptBody: some View {
        Text("Transcript").font(.headline)
        if draft.transcriptSegments.isEmpty {
            Text(transcriptEmptyState).foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(draft.transcriptSegments) { segment in
                    segmentRow(segment)
                }
            }
        }
    }

    private var transcriptEmptyState: String {
        switch draft.processingState {
        case .captured: "Not transcribed yet."
        case .queued: "Queued for transcription."
        case .processing: "Transcribing…"
        case .ready: "No transcript."
        case .failed: "Transcription failed."
        }
    }

    private func segmentRow(_ segment: TranscriptSegment) -> some View {
        let isActive = playback.currentTime >= segment.startTime && playback.currentTime < segment.endTime
        return HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(segment.startTime.formattedDuration)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 48, alignment: .trailing)
            Text(segment.text).textSelection(.enabled)
        }
        .padding(6)
        .background(isActive ? Color.accentColor.opacity(0.15) : .clear, in: RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
        .onTapGesture { playback.seek(to: segment.startTime) }
    }

    private var playerBar: some View {
        HStack(spacing: 12) {
            Button(action: { playback.toggle() }) {
                Image(systemName: playback.isPlaying ? "pause.fill" : "play.fill")
            }
            .disabled(!playback.isReady)
            if let duration = playback.duration, duration > 0 {
                Slider(
                    value: Binding(
                        get: { playback.currentTime },
                        set: { playback.seek(to: $0) }
                    ),
                    in: 0...duration
                )
                .disabled(!playback.isReady)
                Text("\(playback.currentTime.formattedDuration) / \(duration.formattedDuration)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            if let error = playback.errorMessage {
                Text(error).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding()
        .background(.bar)
    }

    private func transcribe() {
        guard let source = settings.transcriptionSource else { return }
        Task { await library.transcribe(draft, source: source) }
    }

    private func summarize() {
        guard let configuration = settings.llmConfiguration else { return }
        Task { await library.generateSummary(draft, configuration: configuration) }
    }
}
