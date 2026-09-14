import Domain
import SwiftUI

struct LibraryDetailView: View {
    @EnvironmentObject private var library: LibraryController
    @EnvironmentObject private var settings: AppSettingsController
    @Environment(\.dismiss) private var dismiss
    @State private var draft: LibraryRecording
    @State private var isWorking = false

    init(recording: LibraryRecording) {
        _draft = State(initialValue: recording)
    }

    var body: some View {
        Form {
            Section("Recording") {
                TextField("Title", text: $draft.title)
                TextField("Tags (comma-separated)", text: Binding(
                    get: { draft.tags.joined(separator: ", ") },
                    set: { draft.tags = $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }
                ))
                LabeledContent("Source", value: draft.source.displayName)
                LabeledContent("State", value: draft.processingState.rawValue.capitalized)
            }
            Section("Notes") { TextEditor(text: $draft.notes).frame(minHeight: 120) }
            Section("Transcript") {
                if draft.transcriptSegments.isEmpty { Text("No transcript yet.").foregroundStyle(.secondary) }
                ForEach(draft.transcriptSegments) { segment in
                    Text("[\(segment.startTime.formatted(.number.precision(.fractionLength(1))))] \(segment.text)")
                }
            }
            Section("Generated") {
                if draft.generatedArtifacts.isEmpty { Text("No generated artifacts.").foregroundStyle(.secondary) }
                ForEach(draft.generatedArtifacts) { artifact in
                    VStack(alignment: .leading) { Text(artifact.kind).font(.caption).foregroundStyle(.secondary); Text(artifact.text) }
                }
            }
            Section("Actions") {
                Button("Save Changes") { Task { await library.save(draft) } }
                Button("Transcribe Locally") { transcribe() }.disabled(settings.transcriptionJobTemplate == nil || isWorking)
                Button("Generate Summary") { summarize() }.disabled(settings.llmConfiguration == nil || draft.transcriptSegments.isEmpty || isWorking)
                Button("Delete Recording", role: .destructive) { Task { await library.delete(draft); dismiss() } }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(draft.title)
        .onReceive(library.$recordings) { recordings in
            if let updated = recordings.first(where: { $0.id == draft.id }) { draft = updated; isWorking = false }
        }
    }

    private func transcribe() {
        guard let template = settings.transcriptionJobTemplate else { return }
        isWorking = true
        Task { await library.transcribe(draft, job: template) }
    }

    private func summarize() {
        guard let configuration = settings.llmConfiguration else { return }
        isWorking = true
        Task { await library.generateSummary(draft, configuration: configuration) }
    }
}
