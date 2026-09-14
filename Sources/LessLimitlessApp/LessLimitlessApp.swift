import PendantKit
import SwiftUI

@main
struct LessLimitlessApp: App {
    @StateObject private var pendantClient = PendantClient()
    @StateObject private var library = LibraryController()

    var body: some Scene {
        WindowGroup {
            AppShellView()
                .environmentObject(pendantClient)
                .environmentObject(library)
                .frame(minWidth: 900, minHeight: 620)
        }
        .windowStyle(.automatic)
    }
}
