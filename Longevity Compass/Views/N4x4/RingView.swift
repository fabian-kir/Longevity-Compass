import SwiftUI
import IntervalEngine

extension RingColor {
    var swiftUIColor: Color {
        switch self {
        case .blue:  return .blue
        case .red:   return .red
        case .green: return .green
        }
    }
}

/// Current-phase progress ring with an arbitrary center overlay (spec §6.1).
/// Progress resets to 0 at each phase boundary — the engine already scopes
/// `phaseProgress` to the current phase, so this view just draws it.
struct RingView<Center: View>: View {
    let progress: Double
    let color: Color
    let lineWidth: CGFloat
    @ViewBuilder var center: () -> Center

    init(progress: Double, color: Color, lineWidth: CGFloat = 18, @ViewBuilder center: @escaping () -> Center) {
        self.progress = progress
        self.color = color
        self.lineWidth = lineWidth
        self.center = center
    }

    var body: some View {
        ZStack {
            Circle()
                .stroke(color.opacity(0.15), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: max(0.0001, min(progress, 1)))
                .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.easeInOut(duration: 0.35), value: progress)
            center()
                .padding(lineWidth * 2)
        }
    }
}
