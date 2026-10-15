import Foundation
import CoreGraphics

public enum LikeState: Equatable {
    case liked, notLiked, unknown
}

/// Recognize action labels, not arbitrary substring matches (e.g. a dislike recommendation).
public enum MenuSemantics {
    public static let addLabels: Set<String> = ["喜欢歌曲", "喜欢", "Like", "Like Song"]
    public static let removeLabels: Set<String> = ["取消喜欢", "取消喜欢歌曲", "Dislike", "Unlike", "Unlike Song"]

    public static func state(title: String, mark: String?, enabled: Bool) -> LikeState {
        guard enabled else { return .unknown }
        let label = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if removeLabels.contains(label) { return .liked }
        guard addLabels.contains(label) else { return .unknown }
        // Any nonempty native checkmark means this toggle is already on.
        if let mark, !mark.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return .liked }
        return .notLiked
    }
}

public enum PositionMode: String, CaseIterable {
    case notchLeft, belowNotch, custom
}

public enum HeartLayout {
    public static let size = CGSize(width: 36, height: 28)

    public static func frame(mode: PositionMode, screen: CGRect, visible: CGRect,
                             leftArea: CGRect?, rightArea: CGRect?) -> CGRect {
        if let left = leftArea, let right = rightArea, left.height >= size.height {
            if mode == .notchLeft {
                return CGRect(x: left.maxX - size.width - 8,
                              y: left.midY - size.height / 2, width: size.width, height: size.height)
            }
            return CGRect(x: (left.maxX + right.minX - size.width) / 2,
                          y: min(left.minY, right.minY) - size.height - 6,
                          width: size.width, height: size.height)
        }
        return CGRect(x: visible.maxX - size.width - 16, y: visible.maxY - size.height - 10,
                      width: size.width, height: size.height)
    }

    public static func clamp(_ frame: CGRect, to screen: CGRect,
                             leftArea: CGRect?, rightArea: CGRect?) -> CGRect {
        var result = frame
        result.origin.x = min(max(result.minX, screen.minX), screen.maxX - result.width)
        result.origin.y = min(max(result.minY, screen.minY), screen.maxY - result.height)
        if let left = leftArea, let right = rightArea {
            let notch = CGRect(x: left.maxX, y: min(left.minY, right.minY),
                               width: right.minX - left.maxX, height: max(left.height, right.height))
            if notch.width > 0 && result.intersects(notch) {
                result.origin.y = notch.minY - result.height - 6
            }
        }
        return result
    }
}

/// A timeout can mean the click actually reached the app. Do not automatically retry.
public struct LikeGate {
    public private(set) var inFlight = false
    public private(set) var needsVerification = false
    public init(needsVerification: Bool = false) { self.needsVerification = needsVerification }
    public mutating func begin(state: LikeState) -> Bool {
        guard state == .notLiked, !inFlight, !needsVerification else { return false }
        inFlight = true
        return true
    }
    public mutating func finish(confirmed: Bool) {
        inFlight = false
        needsVerification = !confirmed
    }
    public mutating func observe(_ state: LikeState) {
        if state == .liked { needsVerification = false }
    }
    /// Only an explicit user acknowledgement may unlock an ambiguous attempt.
    public mutating func acknowledgeUnverifiedAttempt() { needsVerification = false }
}
