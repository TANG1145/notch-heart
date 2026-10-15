import Foundation
import CoreGraphics
import HeartCore

struct HeartCoreChecks {
    func testMenuActionLabelsAndCheckmarks() {
        expectEqual(MenuSemantics.state(title: "喜欢歌曲", mark: nil, enabled: true), .notLiked)
        expectEqual(MenuSemantics.state(title: "取消喜欢", mark: nil, enabled: true), .liked)
        expectEqual(MenuSemantics.state(title: "Like", mark: "✓", enabled: true), .liked)
        expectEqual(MenuSemantics.state(title: "不喜欢这类歌曲", mark: nil, enabled: true), .unknown)
        expectEqual(MenuSemantics.state(title: "喜欢歌曲", mark: nil, enabled: false), .unknown)
        expectEqual(MenuSemantics.state(title: "收藏到歌单", mark: nil, enabled: true), .unknown)
    }

    func testRepeatedClicksAndAmbiguousCompletionNeverRetry() {
        var gate = LikeGate()
        expectFalse(gate.begin(state: .liked))
        expectFalse(gate.begin(state: .unknown))
        expectTrue(gate.begin(state: .notLiked))
        expectFalse(gate.begin(state: .notLiked))
        gate.finish(confirmed: false)
        gate.observe(.notLiked)
        expectFalse(gate.begin(state: .notLiked))
        gate.observe(.liked)
        expectFalse(gate.begin(state: .liked))
        expectTrue(gate.begin(state: .notLiked)) // a subsequent unliked track
    }

    func testExplicitAcknowledgementUnlocksFailedAttempt() {
        var gate = LikeGate()
        expectTrue(gate.begin(state: .notLiked))
        gate.finish(confirmed: false)
        gate.acknowledgeUnverifiedAttempt()
        expectTrue(gate.begin(state: .notLiked))
    }

    func testRestartPreservesAmbiguousAttempt() {
        var gate = LikeGate(needsVerification: true)
        expectFalse(gate.begin(state: .notLiked))
        gate.observe(.liked)
        expectTrue(gate.begin(state: .notLiked))
    }

    func testNotchAndSecondaryScreenGeometry() {
        let screen = CGRect(x: -1512, y: 80, width: 1512, height: 982)
        let left = CGRect(x: -1512, y: 1024, width: 660, height: 38)
        let right = CGRect(x: -660, y: 1024, width: 660, height: 38)
        let visible = CGRect(x: -1512, y: 110, width: 1512, height: 914)
        let beside = HeartLayout.frame(mode: .notchLeft, screen: screen, visible: visible, leftArea: left, rightArea: right)
        expectTrue(left.contains(beside))
        let below = HeartLayout.frame(mode: .belowNotch, screen: screen, visible: visible, leftArea: left, rightArea: right)
        expectEqual(below.midX, screen.midX)
        expectTrue(below.maxY < left.minY)
        let obscured = CGRect(x: screen.midX - 18, y: 1030, width: 36, height: 28)
        let rescued = HeartLayout.clamp(obscured, to: screen, leftArea: left, rightArea: right)
        expectTrue(rescued.maxY < left.minY)
    }

    func testNoNotchFallbackAndOffscreenRecovery() {
        let screen = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let visible = CGRect(x: 0, y: 40, width: 1920, height: 1016)
        let fallback = HeartLayout.frame(mode: .notchLeft, screen: screen, visible: visible, leftArea: nil, rightArea: nil)
        expectTrue(visible.contains(fallback))
        let offscreen = CGRect(x: 3000, y: -100, width: 36, height: 28)
        expectTrue(screen.contains(HeartLayout.clamp(offscreen, to: screen, leftArea: nil, rightArea: nil)))
    }
}


private func expectTrue(_ condition: @autoclosure () -> Bool, file: StaticString = #file, line: UInt = #line) {
    guard condition() else { fatalError("Expected true", file: file, line: line) }
}
private func expectFalse(_ condition: @autoclosure () -> Bool, file: StaticString = #file, line: UInt = #line) {
    guard !condition() else { fatalError("Expected false", file: file, line: line) }
}
private func expectEqual<T: Equatable>(_ a: T, _ b: T, file: StaticString = #file, line: UInt = #line) {
    guard a == b else { fatalError("Expected \(a) == \(b)", file: file, line: line) }
}

@main
struct Runner {
    static func main() {
        let checks = HeartCoreChecks()
        checks.testMenuActionLabelsAndCheckmarks()
        checks.testRepeatedClicksAndAmbiguousCompletionNeverRetry()
        checks.testExplicitAcknowledgementUnlocksFailedAttempt()
        checks.testRestartPreservesAmbiguousAttempt()
        checks.testNotchAndSecondaryScreenGeometry()
        checks.testNoNotchFallbackAndOffscreenRecovery()
        print("PASS: 6 behavior groups (menu semantics, duplicate protection, acknowledgement, restart, notch layout, screen recovery)")
    }
}
