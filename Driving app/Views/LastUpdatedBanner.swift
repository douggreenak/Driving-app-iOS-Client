import SwiftUI

/// Apple-Weather-style freshness line: while a background refresh is in flight (and we already
/// have older data on screen), show a spinner + "Updated <relative time>". It disappears as soon
/// as the fresh data lands.
struct LastUpdatedBanner: View {
    let lastUpdated: Date?
    let isRefreshing: Bool

    var body: some View {
        Group {
            if isRefreshing, let lastUpdated {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text("Updated \(lastUpdated, format: .relative(presentation: .named))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
                .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: isRefreshing)
    }
}
