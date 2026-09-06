import AppKit
import SwiftUI
import TokenBallCore

@main
struct TokenUsageApp: App {
    init() {
        // The status item is created after NSApplication has finished setting up
        // its event loop. No panel is shown at launch; the item is the sole
        // entry point for the app.
        DispatchQueue.main.async {
            TokenUsageController.shared.start()
        }
    }

    var body: some Scene {
        // TokenBall is a menu-bar-only app. Keeping an empty Settings scene
        // gives SwiftUI App a valid scene without creating a Dock window.
        Settings {
            EmptyView()
        }
    }
}

@MainActor
private final class TokenUsagePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// The status button remains the event target; the SwiftUI label is display
/// only and must not swallow the button's mouse events.
@MainActor
private final class PassthroughHostingView<Content: View>: NSHostingView<Content> {
    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }
}

/// Owns the menu-bar item and the panel it presents below that item.
///
/// AppKit is used for the shell so the status item can distinguish a left
/// click from a right click. The panel itself remains SwiftUI-driven and is
/// intentionally kept independent from the content implementation.
@MainActor
final class TokenUsageController: NSObject {
    static let shared = TokenUsageController()

    // The shell is deliberately proportional to the display. Keeping these
    // values in one place makes the compact CodexBar-like density consistent
    // while still allowing the panel to fit a smaller laptop display.
    private static let panelWidthFraction: CGFloat = 0.27
    private static let minimumPanelWidth: CGFloat = 430
    private static let maximumPanelWidth: CGFloat = 540
    private static let panelHeightFraction: CGFloat = 0.74
    private static let panelHeightToWidthRatio: CGFloat = 1.42
    private static let panelScreenInset: CGFloat = 12
    private static let panelGap: CGFloat = 8
    private static let menuBarItemWidth: CGFloat = 82

    private let viewModel = UsageViewModel(repository: SQLiteUsageRepository())
    private var statusItem: NSStatusItem?
    private var panel: NSPanel?
    private var localMouseMonitor: Any?
    private var globalMouseMonitor: Any?
    private var hasStarted = false

    private override init() {
        super.init()
    }

    func start() {
        guard !hasStarted else { return }
        hasStarted = true

        // LSUIElement in the packaged app prevents a Dock icon from appearing
        // before this call; setting the policy here also covers development
        // launches via `swift run`.
        NSApp.setActivationPolicy(.accessory)
        configureStatusItem()
        installOutsideClickMonitors()

        // The old floating-ball view started collection through its .task.
        // The menu-bar shell has no always-present SwiftUI view, so start the
        // same observable model explicitly.
        Task { @MainActor [weak self] in
            await self?.viewModel.startIfNeeded()
        }
    }

    private func configureStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: Self.menuBarItemWidth)
        statusItem = item

        guard let button = item.button else { return }
        button.title = ""
        button.image = nil
        button.imagePosition = .imageOnly
        button.isBordered = false
        button.focusRingType = .none
        button.toolTip = "Token Usage"
        button.target = self
        button.action = #selector(statusItemAction(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])

        // NSStatusBarButton is an AppKit view, while the label is SwiftUI so
        // it can observe UsageViewModel and update after each refresh.
        let hostingView = PassthroughHostingView(rootView: MenuBarLabelView(viewModel: viewModel))
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = NSColor.clear.cgColor
        hostingView.layer?.isOpaque = false
        button.addSubview(hostingView)
        NSLayoutConstraint.activate([
            hostingView.leadingAnchor.constraint(equalTo: button.leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: button.trailingAnchor),
            hostingView.topAnchor.constraint(equalTo: button.topAnchor),
            hostingView.bottomAnchor.constraint(equalTo: button.bottomAnchor)
        ])
    }

    @objc private func statusItemAction(_ sender: Any?) {
        guard let event = NSApp.currentEvent else {
            togglePanel()
            return
        }

        // Control-click is the conventional right-click equivalent on macOS.
        let isRightClick = event.type == .rightMouseUp
            || (event.type == .leftMouseUp && event.modifierFlags.contains(.control))
        if isRightClick {
            showContextMenu()
        } else if event.type == .leftMouseUp {
            togglePanel()
        }
    }

    private func showContextMenu() {
        let menu = NSMenu(title: "Token Usage")
        menu.autoenablesItems = false

        let restartItem = NSMenuItem(
            title: "重启 Token Usage",
            action: #selector(restartApplication),
            keyEquivalent: ""
        )
        restartItem.target = self
        menu.addItem(restartItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(
            title: "退出 Token Usage",
            action: #selector(quitApplication),
            keyEquivalent: "q"
        )
        quitItem.target = self
        menu.addItem(quitItem)

        guard let button = statusItem?.button else { return }
        // Pop the native menu from the status button so it follows the same
        // placement and dismissal behavior as other menu-bar applications.
        menu.popUp(
            positioning: nil,
            at: NSPoint(x: button.bounds.midX, y: button.bounds.minY),
            in: button
        )
    }

    @objc private func restartApplication() {
        hidePanel()

        let applicationURL = Bundle.main.bundleURL
        // `swift run` and Xcode's executable launch do not have an .app bundle.
        // Never terminate the current process in those development modes when
        // there is nothing Launch Services can relaunch.
        guard applicationURL.pathExtension.caseInsensitiveCompare("app") == .orderedSame else {
            return
        }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.createsNewApplicationInstance = true

        NSWorkspace.shared.openApplication(
            at: applicationURL,
            configuration: configuration
        ) { [weak self] _, error in
            Task { @MainActor [weak self] in
                guard error == nil else { return }
                self?.terminateCurrentApplication()
            }
        }
    }

    @objc private func quitApplication() {
        terminateCurrentApplication()
    }

    private func terminateCurrentApplication() {
        hidePanel()
        NSApp.terminate(nil)
    }

    private func togglePanel() {
        guard let panel else {
            showPanel()
            return
        }

        if panel.isVisible {
            hidePanel()
        } else {
            showPanel()
        }
    }

    private func showPanel() {
        let panel = panel ?? makePanel()
        self.panel = panel
        panel.setFrame(panelFrame(), display: true, animate: false)
        panel.orderFrontRegardless()
        // The custom panel can become key without activating the application,
        // allowing SwiftUI's ScrollView and keyboard navigation to work.
        panel.makeKey()
    }

    private func hidePanel() {
        panel?.orderOut(nil)
    }

    private func makePanel() -> NSPanel {
        let initialSize = panelSize(for: statusItemScreen())
        let rootView = UsagePanelView(viewModel: viewModel)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        let hostingView = NSHostingView(rootView: rootView)
        hostingView.frame = NSRect(origin: .zero, size: initialSize)
        hostingView.autoresizingMask = [.width, .height]
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = NSColor.clear.cgColor
        hostingView.layer?.isOpaque = false

        let panel = TokenUsagePanel(
            contentRect: NSRect(origin: .zero, size: initialSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.contentView = hostingView
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.isMovable = false
        panel.isMovableByWindowBackground = false
        panel.hidesOnDeactivate = false
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.animationBehavior = .utilityWindow
        return panel
    }

    private func panelFrame() -> NSRect {
        let screen = statusItemScreen()
        let visibleFrame = screen.visibleFrame
        let size = panelSize(for: screen)

        let statusFrame = statusItemScreenFrame()
        let preferredX = statusFrame.midX - size.width / 2
        let x = clamped(
            preferredX,
            minimum: visibleFrame.minX + Self.panelScreenInset,
            maximum: visibleFrame.maxX - size.width - Self.panelScreenInset
        )

        // Screen coordinates grow upward. The status bar is above visibleFrame,
        // so subtracting the panel height places the panel below the item.
        let preferredY = statusFrame.minY - Self.panelGap - size.height
        let y = clamped(
            preferredY,
            minimum: visibleFrame.minY + Self.panelScreenInset,
            maximum: visibleFrame.maxY - size.height - Self.panelScreenInset
        )

        return NSRect(origin: NSPoint(x: x, y: y), size: size)
    }

    /// Returns a compact point size derived from the display's visible frame.
    /// Width is proportional to the physical display width, then converted
    /// back to points using that display's backing scale. This avoids a fixed
    /// pixel target while keeping the same visual density across Retina and
    /// non-Retina screens.
    private func panelSize(for screen: NSScreen) -> NSSize {
        let visibleFrame = screen.visibleFrame
        let backingScale = max(1, screen.backingScaleFactor)
        let visibleWidthPixels = visibleFrame.width * backingScale
        let proportionalWidthPixels = visibleWidthPixels * Self.panelWidthFraction
        let minimumWidthPixels = Self.minimumPanelWidth * backingScale
        let maximumWidthPixels = Self.maximumPanelWidth * backingScale
        let panelWidthPixels = min(
            maximumWidthPixels,
            max(minimumWidthPixels, proportionalWidthPixels)
        )
        let targetWidth = panelWidthPixels / backingScale
        let targetHeight = targetWidth * Self.panelHeightToWidthRatio
        let availableWidth = max(1, visibleFrame.width - Self.panelScreenInset * 2)
        let availableHeight = max(1, visibleFrame.height - Self.panelScreenInset * 2)
        let heightBudget = min(targetHeight, availableHeight * Self.panelHeightFraction)
        let fitWidth = min(targetWidth, heightBudget / Self.panelHeightToWidthRatio)
        let width = min(availableWidth, fitWidth)

        return NSSize(
            width: max(1, width),
            height: max(1, width * Self.panelHeightToWidthRatio)
        )
    }

    private func statusItemScreen() -> NSScreen {
        if let screen = statusItem?.button?.window?.screen {
            return screen
        }

        let statusFrame = statusItemScreenFrame()
        if let screen = NSScreen.screens.first(where: { $0.frame.intersects(statusFrame) }) {
            return screen
        }
        return NSScreen.main ?? NSScreen.screens[0]
    }

    private func statusItemScreenFrame() -> NSRect {
        guard let button = statusItem?.button,
              let buttonWindow = button.window else {
            let visibleFrame = (NSScreen.main ?? NSScreen.screens[0]).visibleFrame
            return NSRect(
                x: visibleFrame.midX,
                y: visibleFrame.maxY,
                width: 1,
                height: 1
            )
        }
        let buttonRectInWindow = button.convert(button.bounds, to: nil)
        return buttonWindow.convertToScreen(buttonRectInWindow)
    }

    private func installOutsideClickMonitors() {
        guard localMouseMonitor == nil, globalMouseMonitor == nil else { return }

        localMouseMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] event in
            self?.handleOutsideClick(event)
            return event
        }

        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] event in
            self?.handleOutsideClick(event)
        }
    }

    private func handleOutsideClick(_ event: NSEvent) {
        guard let panel, panel.isVisible else { return }

        let location = NSEvent.mouseLocation
        guard !panel.frame.contains(location), !statusItemFrame().contains(location) else {
            return
        }

        hidePanel()
    }

    private func statusItemFrame() -> NSRect {
        statusItemScreenFrame()
    }

    private func clamped(_ value: CGFloat, minimum: CGFloat, maximum: CGFloat) -> CGFloat {
        guard maximum >= minimum else { return minimum }
        return min(maximum, max(minimum, value))
    }
}
