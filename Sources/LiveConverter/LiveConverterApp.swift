import SwiftUI

/// Default Live Photo duration, in seconds (Apple's own Live Photos are ~3s).
/// In-app this is adjustable from 1–10s; this constant is just the first-run default.
let kLivePhotoDuration: Double = 3.0

@main
struct LiveConverterApp: App {
    var body: some Scene {
        WindowGroup("video2live") {
            ContentView()
                .frame(minWidth: 860, minHeight: 760)
        }
        .windowResizability(.contentMinSize)
    }
}
