import PendantKit
import SwiftUI

@main
struct LessLimitlessApp: App {
    @StateObject private var pendantClient = PendantClient()
    @StateObject private var library = LibraryController()
    @StateObject private var settings = AppSettingsController()

    var body: some Scene {
        WindowGroup {
            AppShellView()
                .environmentObject(pendantClient)
                .environmentObject(library)
                .environmentObject(settings)
                .frame(minWidth: 900, minHeight: 620)
        }
        .windowStyle(.automatic)
    }
}
