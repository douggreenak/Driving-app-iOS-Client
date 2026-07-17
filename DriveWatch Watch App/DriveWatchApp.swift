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
                .onAppear {
                    #if DEBUG
                    // Headless screenshots: seed sample data instead of waiting on the phone link.
                    let env = ProcessInfo.processInfo.environment
                    if env["WATCH_PREVIEW"] != nil {
                        link.payload = .sample
                        if env["WATCH_PREVIEW_LIVE"] != nil { link.live = WatchSyncPayload.sampleLive }
                        return
                    }
                    #endif
                    link.activate()
                }
        }
    }
}
