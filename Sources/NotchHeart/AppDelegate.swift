import AppKit
import ApplicationServices
import HeartCore

private struct Preferences {
    let demo: Bool
    private func key(_ name: String) -> String { demo ? "demo.\(name)" : name }
    func bool(forKey name: String) -> Bool { UserDefaults.standard.bool(forKey: key(name)) }
    func string(forKey name: String) -> String? { UserDefaults.standard.string(forKey: key(name)) }
    func integer(forKey name: String) -> Int { UserDefaults.standard.integer(forKey: key(name)) }
    func double(forKey name: String) -> Double { UserDefaults.standard.double(forKey: key(name)) }
    func set(_ value: Any, forKey name: String) { UserDefaults.standard.set(value, forKey: key(name)) }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let demo = CommandLine.arguments.contains("--demo") || Bundle.main.object(forInfoDictionaryKey: "NotchHeartDemo") as? Bool == true
    private lazy var bridge = MusicBridge(demo: demo)
    private lazy var defaults = Preferences(demo: demo)
    private var panel: HeartPanel!
    private var heart: HeartView!
    private var toast: HeartPanel?
    private var toastTask: Task<Void, Never>?
    private var timer: Timer?
    private var refreshBusy = false
    private var gate = LikeGate()
    private var snapshot = MusicSnapshot(message: "正在连接网易云音乐…", diagnostics: "Starting")
    private var settingsWindow: NSWindow?
    private var statusLabel: NSTextField?
    private var mode: PositionMode { PositionMode(rawValue: defaults.string(forKey: "position") ?? "") ?? .notchLeft }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        gate = LikeGate(needsVerification: defaults.bool(forKey: "needsVerification"))
        panel = HeartPanel(contentRect: NSRect(origin: .zero, size: HeartLayout.size),
                           styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = demo ? "Notch Heart · 演示" : "Notch Heart"
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        heart = HeartView(frame: NSRect(origin: .zero, size: HeartLayout.size))
        heart.onClick = { [weak self] in self?.likeCurrent() }
        heart.onMenu = { [weak self] event in self?.showMenu(event) }
        heart.onDragEnd = { [weak self] in self?.saveDraggedPosition() }
        panel.contentView = heart
        restorePosition()
        panel.orderFrontRegardless()
        NotificationCenter.default.addObserver(self, selector: #selector(screenChanged),
                                               name: NSApplication.didChangeScreenParametersNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(screenChanged),
                                                          name: NSWorkspace.didWakeNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(spaceChanged),
                                                          name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        refresh()
        if !demo && !defaults.bool(forKey: "hasSeenWelcome") {
            defaults.set(true, forKey: "hasSeenWelcome")
            showSettings()
        }
        if demo { showToast("演示模式 · 不会修改网易云音乐") }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        restorePosition()
        panel.orderFrontRegardless()
        showSettings()
        return true
    }

    private func screenID(_ screen: NSScreen) -> Int {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.intValue ?? 0
    }

    private func preferredScreen() -> NSScreen? {
        if mode == .custom, let saved = NSScreen.screens.first(where: { screenID($0) == defaults.integer(forKey: "screenID") }) {
            return saved
        }
        return NSScreen.screens.first(where: { $0.auxiliaryTopLeftArea != nil }) ?? NSScreen.main ?? NSScreen.screens.first
    }

    private func restorePosition() {
        guard let screen = preferredScreen() else { return }
        var frame = HeartLayout.frame(mode: mode, screen: screen.frame, visible: screen.visibleFrame,
                                      leftArea: screen.auxiliaryTopLeftArea, rightArea: screen.auxiliaryTopRightArea)
        if mode == .custom && screenID(screen) == defaults.integer(forKey: "screenID") {
            frame.origin = NSPoint(x: screen.frame.minX + defaults.double(forKey: "offsetX"),
                                   y: screen.frame.minY + defaults.double(forKey: "offsetY"))
        }
        frame = HeartLayout.clamp(frame, to: screen.frame,
                                  leftArea: screen.auxiliaryTopLeftArea, rightArea: screen.auxiliaryTopRightArea)
        panel.setFrame(frame, display: true)
    }

    private func saveDraggedPosition() {
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? panel.screen else {
            restorePosition(); return
        }
        let frame = HeartLayout.clamp(panel.frame, to: screen.frame,
                                      leftArea: screen.auxiliaryTopLeftArea, rightArea: screen.auxiliaryTopRightArea)
        panel.setFrame(frame, display: true)
        defaults.set(PositionMode.custom.rawValue, forKey: "position")
        defaults.set(screenID(screen), forKey: "screenID")
        defaults.set(frame.minX - screen.frame.minX, forKey: "offsetX")
        defaults.set(frame.minY - screen.frame.minY, forKey: "offsetY")
        toast?.orderOut(nil)
    }

    @objc private func screenChanged() { restorePosition(); panel.orderFrontRegardless(); toast?.orderOut(nil) }
    @objc private func spaceChanged() { panel.orderFrontRegardless(); toast?.orderOut(nil) }

    private func apply(_ value: MusicSnapshot) {
        snapshot = value
        gate.observe(value.state)
        defaults.set(gate.needsVerification, forKey: "needsVerification")
        heart.state = gate.needsVerification ? .unknown : value.state
        heart.toolTip = gate.needsVerification ? "尚未确认结果 · 右键查看说明" : value.message
        statusLabel?.stringValue = statusText()
    }

    private func refresh() {
        guard !refreshBusy, !gate.inFlight else { return }
        refreshBusy = true
        Task {
            let value = await bridge.snapshot()
            refreshBusy = false
            if !gate.inFlight { apply(value) }
        }
    }

    private func likeCurrent() {
        guard !gate.inFlight else { return }
        if gate.needsVerification { showToast("上次结果未确认 · 右键查看说明"); return }
        if snapshot.needsPermission { showSettings(); return }
        if snapshot.state == .liked { showToast("已经喜欢这首歌了"); return }
        guard gate.begin(state: snapshot.state) else { showToast(snapshot.message); refresh(); return }
        performAction(liked: true)
    }

    private func performAction(liked: Bool) {
        defaults.set(true, forKey: "needsVerification")
        heart.busy = true
        Task {
            let result = await bridge.setLiked(liked)
            gate.finish(confirmed: result.confirmed || !result.sent)
            heart.busy = false
            apply(result.snapshot)
            showToast(result.confirmed ? (liked ? "♥ 已喜欢当前歌曲" : "已取消喜欢当前歌曲") : result.snapshot.message)
        }
    }

    @objc private func unlikeCurrent() {
        guard snapshot.state == .liked, gate.begin(state: .notLiked) else { return }
        performAction(liked: false)
    }

    private func showToast(_ text: String) {
        toastTask?.cancel()
        toast?.orderOut(nil)
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.alignment = .center
        label.textColor = .labelColor
        let width: CGFloat = min(340, max(200, CGFloat(text.count) * 12 + 32))
        let size = CGSize(width: width, height: 54)
        let bubble = HeartPanel(contentRect: NSRect(origin: .zero, size: size),
                                styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        bubble.backgroundColor = .clear
        bubble.isOpaque = false
        bubble.hasShadow = true
        bubble.hidesOnDeactivate = false
        bubble.ignoresMouseEvents = true
        bubble.level = panel.level
        bubble.collectionBehavior = panel.collectionBehavior
        let background = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        background.material = .popover
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 12
        background.layer?.masksToBounds = true
        label.frame = NSRect(x: 12, y: 9, width: width - 24, height: 36)
        background.addSubview(label)
        bubble.contentView = background
        if let screen = panel.screen ?? preferredScreen() {
            let visible = screen.visibleFrame
            let x = min(max(panel.frame.midX - width / 2, visible.minX + 8), visible.maxX - width - 8)
            let below = min(panel.frame.minY - size.height - 8, visible.maxY - size.height - 8)
            let y = below < visible.minY + 8 ? min(panel.frame.maxY + 8, visible.maxY - size.height - 8) : below
            bubble.setFrameOrigin(NSPoint(x: x, y: y))
        }
        toast = bubble
        bubble.orderFrontRegardless()
        toastTask = Task {
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            guard !Task.isCancelled else { return }
            bubble.orderOut(nil)
        }
    }

    private func item(_ title: String, action: Selector?, enabled: Bool = true) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.isEnabled = enabled
        return item
    }

    private func showMenu(_ event: NSEvent) {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.addItem(item(demo ? "Notch Heart · 演示模式" : "Notch Heart", action: nil, enabled: false))
        menu.addItem(item(snapshot.message, action: nil, enabled: false))
        menu.addItem(.separator())
        menu.addItem(item("取消喜欢当前歌曲", action: #selector(unlikeCurrent), enabled: snapshot.state == .liked && !gate.inFlight && !gate.needsVerification))
        menu.addItem(.separator())
        let left = item("放在刘海左侧", action: #selector(positionLeft)); left.state = mode == .notchLeft ? .on : .off
        let below = item("放在刘海下方", action: #selector(positionBelow)); below.state = mode == .belowNotch ? .on : .off
        menu.addItem(left); menu.addItem(below)
        menu.addItem(item("也可以直接拖动红心调整位置", action: nil, enabled: false))
        menu.addItem(.separator())
        menu.addItem(item("设置与连接状态…", action: #selector(showSettings)))
        menu.addItem(item("退出 Notch Heart", action: #selector(quit)))
        NSMenu.popUpContextMenu(menu, with: event, for: heart)
    }

    @objc private func positionLeft() { setPosition(.notchLeft) }
    @objc private func positionBelow() { setPosition(.belowNotch) }
    private func setPosition(_ mode: PositionMode) {
        defaults.set(mode.rawValue, forKey: "position")
        restorePosition()
        panel.orderFrontRegardless()
        toast?.orderOut(nil)
    }
    @objc private func quit() { NSApp.terminate(nil) }

    private func statusText() -> String {
        let message = gate.needsVerification ? "上次操作尚未确认。请到网易云检查收藏状态，再解锁重试。" : snapshot.message
        return "\(demo ? "演示模式\n" : "")\(message)\n\n\(snapshot.diagnostics)"
    }

    @objc private func showSettings() {
        panel.orderOut(nil)
        toast?.orderOut(nil)
        if let settingsWindow { settingsWindow.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 490, height: 550),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Notch Heart · 设置"
        window.isReleasedWhenClosed = false
        window.delegate = self
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        window.contentView!.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: window.contentView!.topAnchor, constant: 24)
        ])
        let title = NSTextField(labelWithString: "喜欢的歌，点一下就好。")
        title.font = .systemFont(ofSize: 23, weight: .semibold)
        stack.addArrangedSubview(title)
        let intro = NSTextField(wrappingLabelWithString: "关闭此窗口后显示悬浮红心。单击喜欢，右键设置，拖动调整位置。左侧菜单拥挤时，切换到刘海下方。")
        stack.addArrangedSubview(intro)
        intro.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        let position = NSStackView(views: [button("刘海左侧", #selector(positionLeft)), button("刘海下方", #selector(positionBelow))])
        position.spacing = 10
        stack.addArrangedSubview(position)
        let permissions = NSTextField(wrappingLabelWithString: "首次使用：在“系统设置 → 隐私与安全性 → 辅助功能”中允许 Notch Heart 控制网易云的“喜欢歌曲”菜单。无需屏幕录制权限，不读取账号或 Cookie。")
        stack.addArrangedSubview(permissions)
        permissions.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        stack.addArrangedSubview(button("打开辅助功能设置…", #selector(openAccessibilitySettings)))
        let label = NSTextField(wrappingLabelWithString: statusText())
        label.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        label.textColor = .secondaryLabelColor
        label.maximumNumberOfLines = 7
        stack.addArrangedSubview(label)
        label.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        label.heightAnchor.constraint(equalToConstant: 100).isActive = true
        statusLabel = label
        let footer = NSStackView(views: [button("重新读取状态", #selector(refreshNow)), button("已核对，解锁重试", #selector(acknowledge)), button("退出", #selector(quit))])
        footer.spacing = 8
        stack.addArrangedSubview(footer)
        settingsWindow = window
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func button(_ title: String, _ action: Selector) -> NSButton { NSButton(title: title, target: self, action: action) }
    func windowWillClose(_ notification: Notification) {
        guard (notification.object as? NSWindow) === settingsWindow else { return }
        restorePosition()
        panel.orderFrontRegardless()
    }
    @objc private func refreshNow() { refresh() }
    @objc private func acknowledge() {
        guard gate.needsVerification, !gate.inFlight else { return }
        let alert = NSAlert()
        alert.messageText = "已在网易云核对收藏状态？"
        alert.informativeText = "上次操作可能已经生效。只有确认当前歌曲尚未喜欢时才解锁，再次点击可能切换收藏状态。解锁本身不会执行收藏。"
        alert.addButton(withTitle: "已核对，解锁")
        alert.addButton(withTitle: "返回")
        if alert.runModal() == .alertFirstButtonReturn {
            gate.acknowledgeUnverifiedAttempt()
            defaults.set(false, forKey: "needsVerification")
            refresh()
        }
    }
    @objc private func openAccessibilitySettings() {
        if !demo {
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
        }
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
}
