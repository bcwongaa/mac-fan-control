import AppKit
import FanControlKit

/// Entry point. @main generates the Swift executable entry point; no main.swift needed.
/// AppDelegate (in FanControlKit) owns the status item, popover, and polling timer.
@main
struct FanControlApp {
    static func main() {
        let delegate = AppDelegate()
        NSApplication.shared.delegate = delegate
        NSApplication.shared.run()
    }
}
