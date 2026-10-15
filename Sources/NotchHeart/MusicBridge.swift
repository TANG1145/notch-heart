import AppKit
import ApplicationServices
import HeartCore

struct MusicSnapshot {
    var state: LikeState = .unknown
    var message: String
    var diagnostics: String
    var needsPermission = false
}

struct MusicActionResult {
    let snapshot: MusicSnapshot
    let sent: Bool
    let confirmed: Bool
}

/// Only uses the local client's native Control menu. No cookies, network API, or keystrokes.
actor MusicBridge {
    static let bundleID = "com.netease.163music"
    private let demo: Bool
    private var demoLiked = false

    init(demo: Bool) { self.demo = demo }

    private func value(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var result: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &result) == .success else { return nil }
        return result
    }

    private func children(_ element: AXUIElement) -> [AXUIElement] {
        value(element, kAXChildrenAttribute) as? [AXUIElement] ?? []
    }

    private func title(_ element: AXUIElement) -> String {
        value(element, kAXTitleAttribute) as? String ?? ""
    }

    private func findItem() -> (AXUIElement?, MusicSnapshot) {
        guard AXIsProcessTrusted() else {
            return (nil, MusicSnapshot(message: "需要辅助功能权限 · 右键打开设置",
                                      diagnostics: "Accessibility permission: not granted", needsPermission: true))
        }
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleID).first else {
            return (nil, MusicSnapshot(message: "请先打开网易云音乐并播放歌曲", diagnostics: "NetEase Music: not running"))
        }
        let root = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(root, 0.6)
        guard let rawBar = value(root, kAXMenuBarAttribute), CFGetTypeID(rawBar) == AXUIElementGetTypeID() else {
            return (nil, MusicSnapshot(message: "暂时无法读取网易云音乐，请稍后重试", diagnostics: "Menu bar unavailable"))
        }
        let bar = unsafeBitCast(rawBar, to: AXUIElement.self)
        // Restrict to Control: a playlist or contextual 'Like' entry must never be pressed.
        guard let control = children(bar).first(where: { ["控制", "Control", "Controls"].contains(title($0)) }) else {
            return (nil, MusicSnapshot(message: "当前网易云版本没有可识别的控制菜单", diagnostics: "Control menu not found"))
        }
        let entries = children(control).flatMap { child -> [AXUIElement] in
            let role = value(child, kAXRoleAttribute) as? String
            return role == kAXMenuRole ? children(child) : [child]
        }
        let labels = entries.map { title($0) }
        guard let item = entries.first(where: {
            MenuSemantics.addLabels.contains(title($0)) || MenuSemantics.removeLabels.contains(title($0))
        }) else {
            return (nil, MusicSnapshot(message: "暂时找不到“喜欢歌曲”，请先播放歌曲",
                                      diagnostics: "Control entries: " + labels.joined(separator: ", ")))
        }
        let itemTitle = title(item)
        let enabled = (value(item, kAXEnabledAttribute) as? Bool) == true
        let mark = value(item, kAXMenuItemMarkCharAttribute) as? String
        let state = MenuSemantics.state(title: itemTitle, mark: mark, enabled: enabled)
        let message: String
        switch state {
        case .liked: message = "已喜欢 · 再点不会取消"
        case .notLiked: message = "点击喜欢网易云音乐当前歌曲"
        case .unknown: message = "当前歌曲暂时无法收藏"
        }
        return (item, MusicSnapshot(state: state, message: message,
                                   diagnostics: "Menu: \(itemTitle)\nEnabled: \(enabled)\nMark: \(mark ?? "(none)")"))
    }

    func snapshot() -> MusicSnapshot {
        if demo {
            return MusicSnapshot(state: demoLiked ? .liked : .notLiked,
                                 message: demoLiked ? "演示：已喜欢 · 再点不会取消" : "演示：点击喜欢《无条件》",
                                 diagnostics: "Demo mode: no real client is read or modified")
        }
        return findItem().1
    }

    func setLiked(_ desired: Bool) async -> MusicActionResult {
        if demo {
            try? await Task.sleep(nanoseconds: 250_000_000)
            demoLiked = desired
            return MusicActionResult(snapshot: snapshot(), sent: true, confirmed: true)
        }
        let (item, before) = findItem() // Recheck immediately before the action; never trust a stale UI snapshot.
        let target: LikeState = desired ? .liked : .notLiked
        if before.state == target { return MusicActionResult(snapshot: before, sent: false, confirmed: true) }
        guard before.state != .unknown, let item else {
            return MusicActionResult(snapshot: before, sent: false, confirmed: false)
        }
        let error = AXUIElementPerformAction(item, kAXPressAction as CFString)
        // Even .cannotComplete can mean success. Never resend the click.
        for wait in [250_000_000, 500_000_000, 1_000_000_000, 1_500_000_000] as [UInt64] {
            try? await Task.sleep(nanoseconds: wait)
            let after = findItem().1
            if after.state == target {
                return MusicActionResult(snapshot: after, sent: true, confirmed: true)
            }
        }
        var after = findItem().1
        after.state = .unknown
        after.message = "尚未确认结果 · 请到网易云检查，暂不重复点击"
        after.diagnostics += "\nAXPress result: \(error.rawValue); result unverified; no retry"
        return MusicActionResult(snapshot: after, sent: true, confirmed: false)
    }
}
