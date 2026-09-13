import PendantKit
import SwiftUI

@main
struct LessLimitlessApp: App {
    @StateObject private var pendantClient = PendantClient()
    var body: some Scene {
        WindowGroup {
            AppShellView()
                .environmentObject(pendantClient)
                .frame(minWidth: 900, minHeight: 620)
        }
        .windowStyle(.automatic)
    }
}
