import Domain
import Foundation

@MainActor
enum SampleData {
    static let recordings: [Recording] = [
        Recording(
            title: "Design review notes",
            source: .macApplication(name: "Video Call"),
            startedAt: Date().addingTimeInterval(-3_900),
            endedAt: Date().addingTimeInterval(-1_860),
            status: .ready,
            note: "Sample content shown for the app shell.",
            tags: ["Design", "Weekly"]
        ),
        Recording(
            title: "Afternoon walk",
            source: .pendant(deviceName: "Sample Pendant"),
            startedAt: Date().addingTimeInterval(-90_000),
            endedAt: Date().addingTimeInterval(-87_420),
            status: .processing,
            tags: ["Ideas"]
        ),
        Recording(
            title: "Imported interview",
            source: .imported,
            startedAt: Date().addingTimeInterval(-176_400),
            endedAt: Date().addingTimeInterval(-173_100),
            status: .ready,
            tags: ["Research"]
        )
    ]

    static let tasks: [ActionItem] = [
        ActionItem(text: "Review the revised prototype", owner: "Me"),
        ActionItem(text: "Share accessibility notes", owner: "Me", dueDate: Date().addingTimeInterval(86_400)),
        ActionItem(text: "Confirm next research session", state: .completed)
    ]
}
