import AppKit
import SwiftUI

/// A borderless, non-activating panel pinned over the notch. It never takes focus, so the app
/// you were using stays frontmost, and it lets clicks through while collapsed.
final class NotchPanel: NSPanel {
    static let expandedSize = CGSize(width: 400, height: 150)

    let notchSize: CGSize

    init(model: NotchModel) {
        let screen = NotchPanel.notchScreen()
        notchSize = NotchPanel.notchSize(on: screen)
        let size = NotchPanel.expandedSize
        let frame = NSRect(x: screen.frame.midX - size.width / 2, y: screen.frame.maxY - size.height,
                           width: size.width, height: size.height)
        super.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 8) // above the menu bar
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        isMovable = false
        ignoresMouseEvents = true
        contentView = NSHostingView(rootView: NotchView(model: model, notch: notchSize, expanded: size))
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// The built-in display if it has a notch, else the main display.
    static func notchScreen() -> NSScreen {
        NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.main ?? NSScreen.screens[0]
    }

    static func notchSize(on screen: NSScreen) -> CGSize {
        let top = screen.safeAreaInsets.top
        if top > 0, let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            return CGSize(width: screen.frame.width - left.width - right.width, height: top)
        }
        // No notch: a small pill under the menu bar.
        return CGSize(width: 180, height: NSStatusBar.system.thickness)
    }
}
