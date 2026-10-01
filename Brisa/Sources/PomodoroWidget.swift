import SwiftUI
import AppKit

/// Floating Pomodoro timer for the desktop, sharing the app's model and theme.
@MainActor
final class BrisaPomodoroWidget: NSObject, ObservableObject, NSWindowDelegate {
    static let shared = BrisaPomodoroWidget()
    private static let size = NSSize(width: 240, height: 284)
    private var panel: NSPanel?
    private var dragStart: (mouse: NSPoint, origin: NSPoint)?

    @Published var enabled = UserDefaults.standard.bool(forKey: "pomodoroWidget.enabled") {
        didSet {
            UserDefaults.standard.set(enabled, forKey: "pomodoroWidget.enabled")
            if enabled { show() } else { panel?.orderOut(nil) }
        }
    }
    @Published var aboveApps = UserDefaults.standard.bool(forKey: "pomodoroWidget.aboveApps") {
        didSet { UserDefaults.standard.set(aboveApps, forKey: "pomodoroWidget.aboveApps"); applyPlacement() }
    }
    @Published var locked = UserDefaults.standard.bool(forKey: "pomodoroWidget.locked") {
        didSet { UserDefaults.standard.set(locked, forKey: "pomodoroWidget.locked") }
    }

    func restore() { if enabled { show() } }
    func hide() { enabled = false }

    func dragFromSurface() {
        guard !locked, let panel else { return }
        let mouse = NSEvent.mouseLocation
        if dragStart == nil { dragStart = (mouse, panel.frame.origin) }
        guard let start = dragStart else { return }
        panel.setFrameOrigin(NSPoint(x: start.origin.x + mouse.x - start.mouse.x,
                                     y: start.origin.y + mouse.y - start.mouse.y))
    }

    func endSurfaceDrag() { dragStart = nil }

    func windowDidMove(_ notification: Notification) {
        guard let panel else { return }
        UserDefaults.standard.set(NSStringFromRect(panel.frame), forKey: "pomodoroWidget.frame")
    }

    private func applyPlacement() {
        panel?.level = aboveApps ? .floating : NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
        panel?.collectionBehavior = aboveApps ? [.canJoinAllSpaces, .fullScreenAuxiliary] : [.canJoinAllSpaces, .stationary]
    }

    private func show() {
        if let panel { applyPlacement(); panel.orderFrontRegardless(); return }
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: Self.size),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = "Brisa Pomodoro Widget"
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = false
        panel.hidesOnDeactivate = false
        panel.contentView = NSHostingView(rootView: PomodoroWidgetView(model: .shared))

        // First launch: bottom-right corner, clear of the mini player's default spot.
        if let screen = NSScreen.main {
            let area = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: area.maxX - Self.size.width - 28, y: area.minY + 28))
        }
        if let saved = UserDefaults.standard.string(forKey: "pomodoroWidget.frame") {
            let frame = NSRectFromString(saved)
            if NSScreen.screens.contains(where: { $0.visibleFrame.intersects(frame) }) {
                panel.setFrame(NSRect(origin: frame.origin, size: Self.size), display: false)
            }
        }
        self.panel = panel
        panel.delegate = self
        applyPlacement()
        panel.orderFrontRegardless()
    }
}

struct PomodoroWidgetView: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var countdown = Countdown.shared
    @ObservedObject private var widget = BrisaPomodoroWidget.shared
    @ObservedObject private var themeStore = BrisaThemeStore.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var theme: BrisaTheme { themeStore.current }
    private var tint: Color { theme.color(for: model.pomodoroPhase) }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 26).fill(.ultraThinMaterial)
            RoundedRectangle(cornerRadius: 26)
                .fill(LinearGradient(colors: [tint.opacity(0.16), theme.shade], startPoint: .topLeading, endPoint: .bottomTrailing))
            VStack(spacing: 10) {
                header
                ring
                taskLine
                controls
            }
            .padding(18)
        }
        .overlay(RoundedRectangle(cornerRadius: 26).strokeBorder(
            LinearGradient(colors: [surface.opacity(theme == .light ? 0.25 : 0.5), .clear, tint.opacity(0.5)],
                           startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 26))
        .frame(width: 240, height: 284)
        .preferredColorScheme(theme.scheme).tint(tint)
        .coordinateSpace(name: "pomodoroSurface")
        .simultaneousGesture(DragGesture(minimumDistance: 8, coordinateSpace: .named("pomodoroSurface"))
            .onChanged { _ in widget.dragFromSurface() }
            .onEnded { _ in widget.endSurfaceDrag() })
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: model.pomodoroPhase.symbol).font(.system(size: 12, weight: .medium))
            Text(model.pomodoroPhase.title.uppercased()).font(.system(size: 10, weight: .bold)).tracking(1.2)
            Spacer()
            Button { widget.aboveApps.toggle() } label: {
                Image(systemName: widget.aboveApps ? "pin.fill" : "pin").frame(width: 20, height: 22)
            }.buttonStyle(.plain).help(widget.aboveApps ? "Keep on desktop" : "Keep above apps")
                .accessibilityLabel(widget.aboveApps ? "Keep widget on desktop" : "Keep widget above apps")
            Button { widget.locked.toggle() } label: {
                Image(systemName: widget.locked ? "lock.fill" : "lock.open").frame(width: 20, height: 22)
            }.buttonStyle(.plain).help(widget.locked ? "Unlock position" : "Lock position")
                .accessibilityLabel(widget.locked ? "Unlock widget position" : "Lock widget position")
            Button { widget.hide() } label: {
                Image(systemName: "xmark").font(.system(size: 10)).frame(width: 20, height: 22)
            }.buttonStyle(.plain).accessibilityLabel("Close Pomodoro widget")
        }
        .foregroundStyle(tint)
    }

    private var ring: some View {
        ZStack {
            Circle().stroke(surface.opacity(0.10), lineWidth: 8)
            Circle().trim(from: 0, to: model.pomodoroProgress)
                .stroke(tint, style: StrokeStyle(lineWidth: 8, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(reduceMotion ? nil : .linear(duration: 0.4), value: model.pomodoroProgress)
            VStack(spacing: 5) {
                Text(model.pomodoroTimeText)
                    .font(.system(size: 36, weight: .light, design: .rounded).monospacedDigit())
                HStack(spacing: 5) {
                    ForEach(0..<model.longBreakInterval, id: \.self) { index in
                        Circle().fill(index < model.pomodoroCycleProgress ? tint : surface.opacity(0.18)).frame(width: 6, height: 6)
                    }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(model.pomodoroCycleProgress) of \(model.longBreakInterval) sessions before long break")
            }
        }
        .frame(width: 132, height: 132)
    }

    private var taskLine: some View {
        HStack(spacing: 5) {
            Image(systemName: "target").font(.system(size: 10)).foregroundStyle(tint)
            if let task = model.activePomodoroTask {
                Text(task.title).lineLimit(1)
                Text("\(task.completedSessions)/\(task.estimate)").font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
            } else {
                Text("No task selected").foregroundStyle(.secondary)
            }
        }
        .font(.system(size: 12, weight: .medium)).frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }

    private var controls: some View {
        HStack(spacing: 14) {
            smallButton("arrow.counterclockwise", "Reset") { model.resetPomodoro() }
            Button { model.isPomodoroRunning ? model.pausePomodoro() : model.startPomodoro() } label: {
                Image(systemName: model.isPomodoroRunning ? "pause.fill" : "play.fill")
                    .font(.system(size: 18, weight: .semibold)).foregroundStyle(theme.onAccent)
                    .frame(width: 46, height: 46).background(tint, in: Circle())
            }
            .buttonStyle(.plain).accessibilityLabel(model.isPomodoroRunning ? "Pause" : "Start")
            smallButton("forward.fill", "Skip phase") { model.skipPomodoro() }
        }
    }

    private func smallButton(_ symbol: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 12, weight: .medium))
                .frame(width: 34, height: 34).background(surface.opacity(0.10), in: Circle())
        }
        .buttonStyle(.plain).help(label).accessibilityLabel(label)
    }
}
