import SwiftUI

/// A dwell-time picker styled after the iOS Clock app's timer wheel.
///
/// When collapsed it shows a single tappable row (e.g. "+30 min at stop 1"). Tapping expands it
/// with a spring animation to reveal two `Picker(.wheel)` columns — **hours** (0–5) and
/// **minutes** (0–59) — arranged and labelled exactly like the Clock timer.
///
/// Bind `minutes` to the total dwell in whole minutes.
struct DwellTimePicker: View {
    /// Total dwell time in minutes. Read and written as whole minutes.
    @Binding var minutes: Int
    /// Label shown in the collapsed row to identify which stop this is (e.g. "at stop 1").
    var stopLabel: String

    @State private var isExpanded = false

    // Decompose into hours (0–5) and minutes (0–59).
    private var selectedHours: Int { minutes / 60 }
    private var selectedMins: Int  { minutes % 60 }

    private var hoursBinding: Binding<Int> {
        Binding(
            get: { selectedHours },
            set: { minutes = $0 * 60 + selectedMins }
        )
    }
    private var minsBinding: Binding<Int> {
        Binding(
            get: { selectedMins },
            set: { minutes = selectedHours * 60 + $0 }
        )
    }

    private var displayLabel: String {
        let h = selectedHours, m = selectedMins
        switch (h, m) {
        case (0, 0): return "No dwell \(stopLabel)"
        case (0, _): return "+\(m) min \(stopLabel)"
        case (_, 0): return "+\(h)h \(stopLabel)"
        default:     return "+\(h)h \(m)m \(stopLabel)"
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // ── Collapsed row ──────────────────────────────────────────────
            Button {
                withAnimation(.spring(response: 0.38, dampingFraction: 0.82)) {
                    isExpanded.toggle()
                }
                Haptics.selection()
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: minutes > 0 ? "clock.badge.fill" : "clock")
                        .foregroundStyle(minutes > 0 ? .orange : .secondary)
                        .font(.subheadline)
                        .contentTransition(.symbolEffect(.replace))

                    Text(displayLabel)
                        .font(.subheadline)
                        .foregroundStyle(minutes > 0 ? .primary : .secondary)
                        .animation(.default, value: displayLabel)

                    Spacer()

                    Image(systemName: "chevron.down")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isExpanded ? 180 : 0))
                }
                .padding(.vertical, 10)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            // ── Expanded wheel ─────────────────────────────────────────────
            if isExpanded {
                timerWheel
                    .transition(.asymmetric(
                        insertion: .push(from: .top).combined(with: .opacity),
                        removal:   .push(from: .bottom).combined(with: .opacity)
                    ))
            }
        }
    }

    // The two-column wheel picker that matches the Clock app layout.
    private var timerWheel: some View {
        GeometryReader { geo in
            HStack(spacing: 0) {
                Spacer()

                // ── Hours column ──────────────────────────
                ZStack(alignment: .trailing) {
                    Picker("Hours", selection: hoursBinding) {
                        ForEach(0...5, id: \.self) { h in
                            Text("\(h)").tag(h)
                        }
                    }
                    .pickerStyle(.wheel)
                    .frame(width: geo.size.width * 0.28)
                    .clipped()

                    Text("hours")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.primary)
                        .offset(x: 52)
                }

                Spacer().frame(width: geo.size.width * 0.18)

                // ── Minutes column ────────────────────────
                ZStack(alignment: .trailing) {
                    Picker("Minutes", selection: minsBinding) {
                        ForEach(0...59, id: \.self) { m in
                            Text(String(format: "%02d", m)).tag(m)
                        }
                    }
                    .pickerStyle(.wheel)
                    .frame(width: geo.size.width * 0.28)
                    .clipped()

                    Text("min")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.primary)
                        .offset(x: 38)
                }

                Spacer()
            }
        }
        .frame(height: 180)
    }
}
