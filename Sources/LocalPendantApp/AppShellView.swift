import Domain
import SwiftUI

struct AppShellView: View {
    @State private var selection: Destination? = .library

    var body: some View {
        NavigationSplitView {
            List(Destination.allCases, selection: $selection) { destination in
                Label(destination.title, systemImage: destination.symbol)
                    .tag(destination)
            }
            .navigationTitle("Local Pendant")
            .safeAreaInset(edge: .bottom) {
                Label("Local only · Preview", systemImage: "lock.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding()
            }
        } detail: {
            destinationView(selection ?? .library)
        }
        .navigationSplitViewStyle(.balanced)
    }

    @ViewBuilder
    private func destinationView(_ destination: Destination) -> some View {
        switch destination {
        case .library: LibraryView()
        case .record: RecordView()
        case .pendant: PendantView()
        case .tasks: TasksView()
        case .settings: SettingsView()
        }
    }
}

enum Destination: String, CaseIterable, Identifiable {
    case library
    case record
    case pendant
    case tasks
    case settings

    var id: Self { self }
    var title: String { rawValue.capitalized }

    var symbol: String {
        switch self {
        case .library: "rectangle.stack"
        case .record: "record.circle"
        case .pendant: "wave.3.right.circle"
        case .tasks: "checklist"
        case .settings: "gearshape"
        }
    }
}
