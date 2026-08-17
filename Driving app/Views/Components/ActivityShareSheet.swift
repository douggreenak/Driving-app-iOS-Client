import SwiftUI
#if canImport(UIKit)
import UIKit

/// Thin wrapper over `UIActivityViewController` — SwiftUI has no built-in way to present the
/// system share sheet for a set of file `URL`s with a single required tap (unlike `ShareLink`,
/// which needs its own extra tap to open and cannot be triggered programmatically from a `Button`
/// action after async prep work, e.g. copying files out first).
struct ActivityShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
#endif
