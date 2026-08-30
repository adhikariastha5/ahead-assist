import SwiftUI

struct DetectedObject: Identifiable, Equatable {
    let id = UUID()
    let label: String
    let confidence: Float
    let boundingBox: CGRect

    var direction: ObjectDirection {
        let centerX = CameraPerspective.userX(for: boundingBox.midX)
        if centerX < 0.333 { return .left }
        if centerX > 0.666 { return .right }
        return .ahead
    }
}

/// The initial, configurable estimate of the user's safe forward travel area.
/// Vision coordinates use a bottom-left origin, so y = 0 is closest to the user.
enum WalkingCorridor {
    static let normalizedPoints = [
        CGPoint(x: 0.10, y: 0.00),
        CGPoint(x: 0.90, y: 0.00),
        CGPoint(x: 0.61, y: 0.62),
        CGPoint(x: 0.39, y: 0.62)
    ]

    static func contains(_ point: CGPoint) -> Bool {
        guard point.y >= 0, point.y <= 0.62 else { return false }
        let progress = point.y / 0.62
        let left = 0.10 + (0.39 - 0.10) * progress
        let right = 0.90 + (0.61 - 0.90) * progress
        return point.x >= left && point.x <= right
    }
}

enum GuidanceLocation {
    case path
    case leftSide
    case rightSide
    case outside
}

/// Uploaded walking footage and the future rear camera are not mirrored: image-right is the user's right.
/// Set this to true only when a mirrored front-camera feed is introduced.
enum CameraPerspective {
    static let isMirrored = false

    static func userX(for imageX: CGFloat) -> CGFloat {
        isMirrored ? 1 - imageX : imageX
    }
}

extension DetectedObject {
    var footPoint: CGPoint {
        CGPoint(x: boundingBox.midX, y: boundingBox.minY)
    }

    var guidanceLocation: GuidanceLocation {
        let userFootPoint = CGPoint(x: CameraPerspective.userX(for: footPoint.x), y: footPoint.y)
        guard boundingBox.height >= 0.10, userFootPoint.y <= 0.62 else { return .outside }
        if WalkingCorridor.contains(userFootPoint) { return .path }
        return userFootPoint.x < 0.5 ? .leftSide : .rightSide
    }

    /// A short, user-relative position description for spoken guidance.
    /// This uses the camera wearer's perspective, not the image viewer's.
    var relativePosition: ObjectDirection {
        let userX = CameraPerspective.userX(for: footPoint.x)
        if userX < 0.38 { return .left }
        if userX > 0.62 { return .right }
        return .ahead
    }
}

enum ObjectDirection: String {
    case left, ahead, right

    var title: String { rawValue.capitalized }

    var color: Color {
        switch self {
        case .left: .orange
        case .ahead: .red
        case .right: .purple
        }
    }
}

struct AlertEvent: Identifiable {
    let id = UUID()
    let timestamp: String
    let message: String
}
