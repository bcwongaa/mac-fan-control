import AppKit
import SwiftUI

public final class AppDelegate: NSObject, NSApplicationDelegate {

    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private let controller = FanController()
    private var pollTimer: Timer?
    private var eventMonitor: Any?
    private var statusView: TwoLineStatusView!

    public override init() { super.init() }

    // MARK: - NSApplicationDelegate

    public func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        setupStatusItem()
        setupPopover()
        startPolling()
        if !controller.helperInstalled {
            controller.installHelper { _ in }
        }
    }

    public func applicationWillTerminate(_ notification: Notification) {
        controller.resetToAutomaticOnQuit()
    }

    // MARK: - Status Bar

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: 54)
        guard let button = statusItem.button else { return }
        button.title = ""
        button.action = #selector(togglePopover)
        button.target = self

        statusView = TwoLineStatusView(button: button)
        button.addSubview(statusView)
    }

    @objc private func togglePopover() {
        if popover.isShown { closePopover() } else { openPopover() }
    }

    private func openPopover() {
        guard let button = statusItem.button else { return }
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)

        // NSPopover may flip position if it miscalculates available space.
        // Reposition after layout to guarantee it always sits below the menu bar.
        DispatchQueue.main.async { [self] in
            guard let popWindow = popover.contentViewController?.view.window,
                  let btnWindow  = button.window else { return }

            let btnScreen = btnWindow.convertToScreen(
                button.convert(button.bounds, to: nil)
            )
            var f = popWindow.frame
            f.origin.y = btnScreen.minY - f.height          // flush below the button
            f.origin.x = btnScreen.midX  - f.width / 2     // horizontally centred

            // Clamp so the popover never pokes outside the screen horizontally
            if let screen = NSScreen.screens.first(where: { $0.frame.contains(btnScreen.origin) })
                            ?? NSScreen.main {
                f.origin.x = max(screen.visibleFrame.minX,
                                 min(f.origin.x, screen.visibleFrame.maxX - f.width))
            }
            popWindow.setFrameOrigin(f.origin)
        }

        eventMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in self?.closePopover() }
    }

    private func closePopover() {
        popover.performClose(nil)
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            eventMonitor = nil
        }
    }

    // MARK: - Popover

    private func setupPopover() {
        let content = MenuView(controller: controller)
        popover = NSPopover()
        popover.contentViewController = NSHostingController(rootView: content)
        popover.behavior = .applicationDefined
    }

    // MARK: - Polling

    private func startPolling() {
        refreshAndUpdateTitle()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            self?.refreshAndUpdateTitle()
        }
    }

    private func refreshAndUpdateTitle() {
        controller.refresh()

        let tempStr = controller.temperature
            .map { String(format: "%.1f°C", $0) } ?? "—°C"

        let rpms = [controller.fan0RPM, controller.fan1RPM].compactMap { $0 }
        let rpmStr: String
        if rpms.isEmpty {
            rpmStr = "·"
        } else {
            let avg = rpms.reduce(0, +) / Double(rpms.count)
            rpmStr = "\(Int(avg)) RPM"
        }

        statusView.update(top: tempStr, bot: rpmStr)
    }
}

// MARK: - Two-line status bar view

/// Draws two lines of text in the status bar button using Core Text so there
/// are zero Auto Layout side-effects on the button's own geometry. Returning
/// nil from hitTest passes all mouse events straight through to the button.
private final class TwoLineStatusView: NSView {

    private weak var button: NSStatusBarButton?
    private var topText = "—°C"
    private var botText = "·"

    init(button: NSStatusBarButton) {
        self.button = button
        super.init(frame: button.bounds)
        autoresizingMask = [.width, .height]   // tracks button size without Auto Layout
    }
    required init?(coder: NSCoder) { fatalError() }

    func update(top: String, bot: String) {
        guard top != topText || bot != botText else { return }
        topText = top
        botText = bot
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        // Use white text when the button is highlighted (popover open / clicked)
        let highlighted = button?.isHighlighted == true
        let primaryColor: NSColor   = highlighted ? .white : .labelColor
        let secondaryColor: NSColor = highlighted ? .white.withAlphaComponent(0.75)
                                                  : .secondaryLabelColor

        let topAttr = NSAttributedString(string: topText, attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .medium),
            .foregroundColor: primaryColor,
        ])
        let botAttr = NSAttributedString(string: botText, attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 8, weight: .regular),
            .foregroundColor: secondaryColor,
        ])

        let topSz = topAttr.size()
        let botSz = botAttr.size()
        let gap: CGFloat = 0
        let totalH = topSz.height + gap + botSz.height
        let baseY   = (bounds.height - totalH) / 2

        botAttr.draw(at: NSPoint(x: (bounds.width - botSz.width) / 2,
                                 y: baseY))
        topAttr.draw(at: NSPoint(x: (bounds.width - topSz.width) / 2,
                                 y: baseY + botSz.height + gap))
    }

    // Clicks fall through to the NSStatusBarButton underneath
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
