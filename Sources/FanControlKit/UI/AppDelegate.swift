import AppKit
import SwiftUI

public final class AppDelegate: NSObject, NSApplicationDelegate {

    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private let controller = FanController()
    private var pollTimer: Timer?
    private var eventMonitor: Any?

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
        // Fixed width prevents the button from resizing as the temperature text
        // changes, which would shift the popover anchor on every open.
        statusItem = NSStatusBar.system.statusItem(withLength: 52)
        if let button = statusItem.button {
            button.title = "—°C"
            button.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
            button.action = #selector(togglePopover)
            button.target = self
        }
    }

    @objc private func togglePopover() {
        if popover.isShown { closePopover() } else { openPopover() }
    }

    private func openPopover() {
        guard let button = statusItem.button else { return }
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
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
        statusItem.button?.title = controller.cpuTemperature
            .map { String(format: "%.0f°C", $0) } ?? "—°C"
    }
}
