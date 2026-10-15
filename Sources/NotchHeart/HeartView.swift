import AppKit
import HeartCore

enum HeartBackground: String, CaseIterable {
    case acrylic, transparent, liquidGlass
    var title: String {
        switch self {
        case .acrylic: return "亚克力"
        case .transparent: return "透明"
        case .liquidGlass: return "液态玻璃"
        }
    }
    static var supportsGlass: Bool {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) { return true }
        #endif
        return false
    }
}

private final class HeartGlyphView: NSView {
    weak var heart: HeartView?
    override func draw(_ dirtyRect: NSRect) { heart?.drawGlyph(in: bounds) }
}

final class HeartPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

final class HeartView: NSView {
    var state: LikeState = .unknown { didSet { glyph.needsDisplay = true; updateAccessibility() } }
    var busy = false { didSet { glyph.needsDisplay = true } }
    var hovered = false { didSet { glyph.needsDisplay = true } }
    var backgroundStyle: HeartBackground = .acrylic { didSet { rebuildBackground() } }
    private let glyph = HeartGlyphView()
    var onClick: (() -> Void)?
    var onMenu: ((NSEvent) -> Void)?
    var onDragEnd: (() -> Void)?
    private var tracking: NSTrackingArea?
    private var startMouse: NSPoint?
    private var startOrigin: NSPoint?
    private var dragged = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        glyph.heart = self
        rebuildBackground()
        updateAccessibility()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var acceptsFirstResponder: Bool { false }
    // Decorative material views must never consume clicks or drag gestures.
    override func hitTest(_ point: NSPoint) -> NSView? {
        bounds.contains(convert(point, from: superview)) ? self : nil
    }

    private func rebuildBackground() {
        glyph.removeFromSuperview()
        subviews.forEach { $0.removeFromSuperview() }
        let contentFrame = bounds.insetBy(dx: 1, dy: 1)
        glyph.autoresizingMask = [.width, .height]
        #if compiler(>=6.2)
        if backgroundStyle == .liquidGlass, #available(macOS 26.0, *) {
            let glass = NSGlassEffectView(frame: contentFrame)
            glass.autoresizingMask = [.width, .height]
            glass.style = .regular
            glass.cornerRadius = 9
            glyph.frame = NSRect(origin: .zero, size: contentFrame.size)
            glass.contentView = glyph
            addSubview(glass)
            return
        }
        #endif
        if backgroundStyle != .transparent {
            let acrylic = NSVisualEffectView(frame: contentFrame)
            acrylic.autoresizingMask = [.width, .height]
            acrylic.material = .hudWindow
            acrylic.blendingMode = .behindWindow
            acrylic.state = .active
            acrylic.wantsLayer = true
            acrylic.layer?.cornerRadius = 9
            acrylic.layer?.masksToBounds = true
            addSubview(acrylic)
        }
        glyph.frame = bounds
        addSubview(glyph)
    }

    private func updateAccessibility() {
        setAccessibilityLabel(state == .liked ? "当前歌曲已喜欢" : "喜欢当前歌曲")
        setAccessibilityValue(state == .liked ? "已喜欢" : state == .notLiked ? "未喜欢" : "状态未知")
        setAccessibilityHelp("单击喜欢当前歌曲；右键打开位置与权限设置；拖动调整位置")
    }
    override func accessibilityPerformPress() -> Bool { onClick?(); return true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area)
        tracking = area
    }
    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false }

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control) { onMenu?(event); return }
        startMouse = NSEvent.mouseLocation
        startOrigin = window?.frame.origin
        dragged = false
    }
    override func mouseDragged(with event: NSEvent) {
        guard let startMouse, let startOrigin else { return }
        let now = NSEvent.mouseLocation
        let dx = now.x - startMouse.x, dy = now.y - startMouse.y
        guard dragged || hypot(dx, dy) > 4 else { return }
        dragged = true
        window?.setFrameOrigin(NSPoint(x: startOrigin.x + dx, y: startOrigin.y + dy))
    }
    override func mouseUp(with event: NSEvent) {
        guard startMouse != nil else { return }
        if dragged { onDragEnd?() }
        else if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?() }
        startMouse = nil
        startOrigin = nil
    }
    override func rightMouseDown(with event: NSEvent) { onMenu?(event) }

    fileprivate func drawGlyph(in bounds: NSRect) {
        let name = busy ? "ellipsis" : state == .liked ? "heart.fill" : state == .unknown ? "heart.slash" : "heart"
        let color = state == .liked && !busy ? NSColor.systemRed : NSColor.labelColor
        let config = NSImage.SymbolConfiguration(pointSize: 17, weight: .medium)
            .applying(.init(paletteColors: [color]))
        if let icon = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(config) {
            let size = icon.size
            icon.draw(in: NSRect(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2,
                                width: size.width, height: size.height))
        }
    }
}
