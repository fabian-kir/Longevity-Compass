import IntervalEngine
import SwiftUI

/// Maps the engine's platform-agnostic `RingColor` to a SwiftUI color. Duplicated
/// from the iOS target because the two apps are separate modules; the mapping is
/// the single source of the spec §6 color scheme on the watch.
extension RingColor {
    var swiftUIColor: Color {
        switch self {
        case .blue:  return .blue
        case .red:   return .red
        case .green: return .green
        }
    }
}

/// Current-phase progress ring with a caller-supplied center (spec §6.2). Thinner
/// stroke than the phone to suit the smaller watch face.
struct RingView<Center: View>: View {
    let progress: Double
    let color: Color
    var lineWidth: CGFloat = 10
    @ViewBuilder var center: () -> Center

    var body: some View {
        ZStack {
            Circle()
                .stroke(color.opacity(0.2), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: max(0, min(progress, 1)))
                .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.easeInOut(duration: 0.3), value: progress)
            center()
        }
    }
}
