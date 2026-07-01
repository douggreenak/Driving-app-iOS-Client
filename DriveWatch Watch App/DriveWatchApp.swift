import SwiftUI

/// Entry point for the Apple Watch companion. Shows upcoming scheduled drives (start one straight
/// from the wrist) and simple driving stats, mirrored from the iPhone over WatchConnectivity.
@main
struct DriveWatchApp: App {
    @State private var link = WatchConnectivityManager.shared

    var body: some Scene {
        WindowGroup {
            WatchContentView()
                .environment(link)
                .onAppear { link.activate() }
        }
    }
}
