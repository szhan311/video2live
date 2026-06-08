import SwiftUI

/// Fixed Live Photo duration, in seconds. Apple's own Live Photos are ~3s.
/// Change this single value if you want a different fixed length.
let kLivePhotoDuration: Double = 3.0

@main
struct LiveConverterApp: App {
    var body: some Scene {
        WindowGroup("video2live") {
            ContentView()
                .frame(minWidth: 720, minHeight: 560)
        }
        .windowResizability(.contentMinSize)
    }
}
