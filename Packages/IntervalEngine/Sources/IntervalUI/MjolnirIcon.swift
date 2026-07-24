import SwiftUI

/// Flat silhouette of Mjölnir: blocky head over a wrap-segmented shaft ending
/// in a pommel loop.
public struct MjolnirIcon: Shape {
    public init() {}

    public func path(in rect: CGRect) -> Path {
        let sx = rect.width / 100
        let sy = rect.height / 100
        func block(_ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat, corner: CGFloat) -> Path {
            Path(
                roundedRect: CGRect(
                    x: rect.minX + x * sx,
                    y: rect.minY + y * sy,
                    width: width * sx,
                    height: height * sy
                ),
                cornerRadius: corner * min(sx, sy)
            )
        }

        var path = Path()
        path.addPath(block(12, 6, 76, 34, corner: 6))
        path.addPath(block(40, 38, 20, 10, corner: 2))
        path.addPath(block(40, 48, 20, 11, corner: 3))
        path.addPath(block(40, 62, 20, 11, corner: 3))
        path.addPath(block(40, 76, 20, 10, corner: 3))
        path.addPath(block(33, 88, 34, 8, corner: 4))
        return path
    }
}
