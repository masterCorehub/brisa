import SwiftUI
import AppKit

/// A borderless panel that still takes key presses, so Return, Escape and typing work on the break screen.
final class BreakScreenPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// Acts on the first click even when another app was in front, instead of spending it on focusing the window.
final class FirstClickHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// The full-screen moment between phases: a focus session ended and a break begins (pick what to do in it),
/// or a break ended and focus is next.
@MainActor
final class BreakScreen: ObservableObject {
    static let shared = BreakScreen()

    enum Moment: Equatable {
        /// A focus session just ended; the break is next.
        case breakStarting
        /// The break runs and the screen stays up with what was picked.
        case duringBreak
        /// A break just ended; focus is next. Keeps which break it was, to offer a few more minutes of it.
        case backToFocus(PomodoroPhase)
    }

    @Published private(set) var moment = Moment.breakStarting
    @Published private(set) var isPreview = false
    /// Changes each time the screen opens, so its choices start fresh.
    @Published private(set) var generation = 0
    private(set) var isShown = false
    private var panels: [NSPanel] = []
    /// The app that was in front before the screen appeared; it gets the focus back afterwards.
    private var previousApp: NSRunningApplication?
    private var pomodoroRequested = false

    private var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    /// Called when a phase runs out on its own. Returns whether the screen came up, so the notification can be skipped.
    func phaseEnded(from finished: PomodoroPhase) -> Bool {
        let store = BreakStore.shared
        if finished == .work {
            guard store.showAfterFocus else { return false }
            show(.breakStarting)
            return true
        }
        guard store.showAfterBreak else {
            if isShown, moment == .duringBreak { close() }
            return false
        }
        show(.backToFocus(finished))
        return true
    }

    func preview(_ moment: Moment) { show(moment, preview: true) }

    func show(_ moment: Moment, preview: Bool = false) {
        self.moment = moment
        isPreview = preview
        generation += 1
        if isShown { panels.first?.makeKeyAndOrderFront(nil); return }
        isShown = true
        present()
        let text: String
        switch moment {
        case .breakStarting: text = "Focus session complete. Time for a break."
        case .duringBreak: text = "On a break."
        case .backToFocus: text = "Break's over. Ready to focus again?"
        }
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                             userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }

    /// Closes the screen. `restoreFocus` hands the keyboard back to the app that was in front, unless
    /// something else (an app an activity opened, Brisa's own window) should have it.
    func close(restoreFocus: Bool = true) {
        guard isShown else { return }
        isShown = false
        let closing = panels
        panels = []
        if restoreFocus, let previousApp, previousApp != NSRunningApplication.current, !previousApp.isTerminated {
            previousApp.activate()
        }
        previousApp = nil
        guard !reduceMotion else { closing.forEach { $0.orderOut(nil) }; return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.25
            closing.forEach { $0.animator().alphaValue = 0 }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { closing.forEach { $0.orderOut(nil) } }
    }

    // MARK: Actions

    /// Starts the break with what was picked (or nothing), then stays up or closes, as set.
    func startBreak(with activity: BreakActivity?, customTitle: String) {
        guard isShown, moment == .breakStarting else { return }
        guard !isPreview else { close(); return }
        let model = AppModel.shared
        let store = BreakStore.shared
        let title = customTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        if activity != nil || !title.isEmpty { store.record(activity, customTitle: title) }
        if model.pomodoroPhase != .work {
            if let minutes = activity?.minutes { model.resizeCurrentPhase(minutes: minutes) }
            if !model.isPomodoroRunning { model.startPomodoro() }
        }
        let target = activity.flatMap { BreakActivities.target($0.opens) }
        // Something that opens an app or a site needs the screen out of the way.
        if store.staysOpen, target == nil { moment = .duringBreak } else { close(restoreFocus: target == nil) }
        if let target { open(target) }
    }

    /// Goes straight back to focusing.
    func skipBreak() {
        if !isPreview {
            let model = AppModel.shared
            if model.pomodoroPhase != .work { model.skipPomodoro() }
            if !model.isPomodoroRunning { model.startPomodoro() }
        }
        close()
    }

    func startFocus() {
        if !isPreview {
            let model = AppModel.shared
            if model.pomodoroPhase == .work, !model.isPomodoroRunning { model.startPomodoro() }
        }
        close()
    }

    /// A few more minutes of the break that just ended.
    func extendBreak(minutes: Int = 5) {
        guard case .backToFocus(let phase) = moment else { return }
        guard !isPreview else { close(); return }
        AppModel.shared.returnToBreak(phase, minutes: minutes)
        if BreakStore.shared.staysOpen { moment = .duringBreak } else { close() }
    }

    /// Opens the Pomodoro page, where the break activities are edited.
    func openSettings() {
        close(restoreFocus: false)
        pomodoroRequested = true
        BrisaWindowActions.showInDock()
        NotificationCenter.default.post(name: Notification.Name("BrisaShowWindow"), object: nil)
        NotificationCenter.default.post(name: Notification.Name("BrisaShowPomodoro"), object: nil)
    }

    /// True once after `openSettings`, for a main window that wasn't open yet.
    func takePomodoroRequest() -> Bool {
        defer { pomodoroRequested = false }
        return pomodoroRequested
    }

    /// The phase is changed elsewhere (skipped, reset) while the break screen is up: it no longer applies.
    func phaseChanged(to phase: PomodoroPhase) {
        guard isShown, !isPreview, phase == .work else { return }
        if moment == .breakStarting || moment == .duringBreak { close() }
    }

    private func open(_ target: URL) {
        if target.isFileURL {
            NSWorkspace.shared.openApplication(at: target, configuration: NSWorkspace.OpenConfiguration()) { _, _ in }
        } else {
            NSWorkspace.shared.open(target)
        }
    }

    // MARK: Windows

    private func present() {
        // Brisa comes to the front so clicks, typing, Return and Escape reach the screen straight away.
        let front = NSWorkspace.shared.frontmostApplication
        previousApp = front == NSRunningApplication.current ? nil : front
        NSApp.activate(ignoringOtherApps: true)
        let mouse = NSEvent.mouseLocation
        guard let main = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) ?? NSScreen.main else { return }
        for screen in NSScreen.screens where screen == main || BreakStore.shared.dimOtherDisplays {
            let isMain = screen == main
            let panel = BreakScreenPanel(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            panel.isReleasedWhenClosed = false
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = false
            panel.hidesOnDeactivate = false
            panel.level = .screenSaver
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            panel.contentView = isMain ? FirstClickHostingView(rootView: BreakScreenView(model: .shared)) : FirstClickHostingView(rootView: BreakBackdrop())
            panel.setFrame(screen.frame, display: false)
            panel.alphaValue = reduceMotion ? 1 : 0
            if isMain { panel.makeKeyAndOrderFront(nil) } else { panel.orderFrontRegardless() }
            panels.append(panel)
        }
        guard !reduceMotion else { return }
        let showing = panels
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.35
            showing.forEach { $0.animator().alphaValue = 1 }
        }
    }
}

// MARK: - Views

/// Covers the other displays while the break screen is up.
private struct BreakBackdrop: View {
    @ObservedObject private var themeStore = BrisaThemeStore.shared

    var body: some View {
        ZStack {
            Rectangle().fill(.ultraThinMaterial)
            LinearGradient(colors: themeStore.current.background, startPoint: .topLeading, endPoint: .bottomTrailing).opacity(0.85)
            Image(systemName: "wind").font(.system(size: 44, weight: .light)).foregroundStyle(accent.opacity(0.35))
        }
        .ignoresSafeArea()
        .preferredColorScheme(themeStore.current.scheme)
    }
}

struct BreakScreenView: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var screen = BreakScreen.shared
    @ObservedObject private var store = BreakStore.shared
    @ObservedObject private var themeStore = BrisaThemeStore.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var selectedID: UUID?
    @State private var custom = ""
    @State private var saveCustom = false
    @State private var breathing = false

    /// The break this screen is about. A preview from the focus phase shows a short break.
    private var breakPhase: PomodoroPhase {
        if case .backToFocus(let phase) = screen.moment { return phase }
        return model.pomodoroPhase == .work ? .shortBreak : model.pomodoroPhase
    }

    private var tint: Color {
        if case .backToFocus = screen.moment { return themeStore.current.color(for: .work) }
        return themeStore.current.color(for: breakPhase)
    }

    private var activities: [BreakActivity] { store.available(for: breakPhase) }
    private var suggestion: BreakActivity? { store.suggestion(for: breakPhase) }

    var body: some View {
        ZStack {
            Rectangle().fill(.ultraThinMaterial)
            LinearGradient(colors: themeStore.current.background, startPoint: .topLeading, endPoint: .bottomTrailing).opacity(0.88)
            // A slow "breathing" glow behind the clock.
            RadialGradient(colors: [tint.opacity(0.2 * themeStore.current.glowStrength), .clear], center: .center, startRadius: 0, endRadius: 460)
                .frame(width: 920, height: 920)
                .scaleEffect(breathing ? 1.08 : 0.9)
                .animation(reduceMotion ? nil : .easeInOut(duration: 4).repeatForever(autoreverses: true), value: breathing)
                .offset(y: -120).allowsHitTesting(false)

            GeometryReader { geo in
                ScrollView {
                    VStack(spacing: 30) {
                        header
                        BreakClock(model: model, moment: screen.moment, isPreview: screen.isPreview, tint: tint, previewMinutes: previewMinutes)
                        switch screen.moment {
                        case .breakStarting: chooser
                        case .duringBreak: doing
                        case .backToFocus: backToFocus
                        }
                    }
                    .frame(maxWidth: 860)
                    .padding(.horizontal, 48).padding(.vertical, 70)
                    .frame(maxWidth: .infinity, minHeight: geo.size.height)
                }
                .scrollIndicators(.never)
            }
        }
        .overlay(alignment: .topTrailing) {
            Button { screen.close() } label: {
                Image(systemName: "xmark").font(.system(size: 14, weight: .semibold)).frame(width: 40, height: 40)
                    .background(surface.opacity(0.1), in: Circle())
            }
            .buttonStyle(.plain).keyboardShortcut(.cancelAction).padding(28)
            .help("Close (Esc). The timer keeps running.").accessibilityLabel("Close break screen")
        }
        .overlay(alignment: .bottom) {
            HStack(spacing: 16) {
                if screen.isPreview { Label("Preview: the timer isn't affected", systemImage: "eye") }
                Button { screen.openSettings() } label: { Label("Customize activities…", systemImage: "slider.horizontal.3") }
                    .buttonStyle(.plain)
            }
            .font(.caption).foregroundStyle(.secondary).padding(.bottom, 26)
        }
        .ignoresSafeArea()
        .preferredColorScheme(themeStore.current.scheme)
        .tint(tint)
        .onAppear { reset(); breathing = true }
        .onChange(of: screen.generation) { _, _ in reset() }
        .onChange(of: model.pomodoroPhase) { _, phase in screen.phaseChanged(to: phase) }
    }

    private func reset() {
        selectedID = screen.moment == .breakStarting ? suggestion?.id : nil
        custom = ""
        saveCustom = false
    }

    // MARK: Header

    private var header: some View {
        VStack(spacing: 10) {
            Text(eyebrow).font(.system(size: 13, weight: .bold)).tracking(1.8).textCase(.uppercase).foregroundStyle(tint)
            Text(title).font(.system(size: 44, weight: .semibold, design: .rounded)).multilineTextAlignment(.center)
            if let detail { Text(detail).font(.system(size: 15)).foregroundStyle(.secondary).multilineTextAlignment(.center) }
        }
    }

    private var eyebrow: String {
        switch screen.moment {
        case .breakStarting: return "Focus session complete"
        case .duringBreak: return breakPhase == .longBreak ? "Long break" : "Short break"
        case .backToFocus: return "Break's over"
        }
    }

    private var title: String {
        switch screen.moment {
        case .breakStarting: return breakPhase == .longBreak ? "Time for a long break" : "Time for a short break"
        case .duringBreak: return store.current?.title ?? "Enjoy your break"
        case .backToFocus: return "Ready to focus again?"
        }
    }

    private var detail: String? {
        switch screen.moment {
        case .breakStarting:
            let done = model.pomodoroSessionsToday.count
            let task = model.activePomodoroTask.map { " · \($0.title)" } ?? ""
            return "\(done) of \(model.pomodoroDailyGoal) sessions today\(task)"
        case .duringBreak:
            guard let current = store.current else { return "Step away from the screen for a moment." }
            let note = store.activities.first { $0.id == current.activityID }?.note ?? ""
            return note.isEmpty ? nil : note
        case .backToFocus:
            if let task = model.activePomodoroTask { return "Next up: \(task.title)" }
            return store.current.map { "You took a break to: \($0.title.lowercased())" }
        }
    }

    private var previewMinutes: Int {
        switch screen.moment {
        case .backToFocus: return model.workMinutes
        default: return breakPhase == .longBreak ? model.longBreakMinutes : model.shortBreakMinutes
        }
    }

    // MARK: Break starting

    private var chooser: some View {
        VStack(spacing: 18) {
            Text("What will you do?").font(.system(size: 20, weight: .semibold, design: .rounded))
            if activities.isEmpty {
                Text("No activities for this break. Add some in Customize activities, or type one below.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), spacing: 14)], spacing: 14) {
                ForEach(activities) { tile($0) }
            }
            HStack(spacing: 10) {
                Image(systemName: "pencil").foregroundStyle(.secondary)
                TextField("Something else…", text: $custom).textFieldStyle(.plain).font(.system(size: 15))
                    .onSubmit(start)
                    .onChange(of: custom) { _, text in if !text.isEmpty { selectedID = nil } }
                    .accessibilityLabel("Something else to do")
                if !custom.trimmingCharacters(in: .whitespaces).isEmpty {
                    Toggle("Save to my list", isOn: $saveCustom).toggleStyle(.checkbox).font(.caption)
                }
            }
            .padding(.horizontal, 18).padding(.vertical, 14)
            .background(surface.opacity(0.06), in: RoundedRectangle(cornerRadius: 16))
            HStack(spacing: 14) {
                Button(action: screen.skipBreak) {
                    Text("Skip break").font(.system(size: 14, weight: .medium)).padding(.horizontal, 22).frame(height: 46)
                        .background(surface.opacity(0.08), in: Capsule())
                }
                .buttonStyle(.plain).help("Go straight back to focusing")
                Button(action: start) {
                    Label(startLabel, systemImage: "play.fill").font(.system(size: 15, weight: .semibold))
                        .padding(.horizontal, 28).frame(height: 46).background(tint, in: Capsule()).foregroundStyle(onAccent)
                }
                .buttonStyle(.plain).keyboardShortcut(.defaultAction)
            }
            .padding(.top, 6)
        }
    }

    private var startLabel: String {
        let running = model.isPomodoroRunning && !screen.isPreview
        guard let activity = activities.first(where: { $0.id == selectedID }) else { return running ? "Enjoy the break" : "Start break" }
        return running ? activity.title : "Start break: \(activity.title.lowercased())"
    }

    private func start() {
        var activity = store.activities.first { $0.id == selectedID }
        let text = custom.trimmingCharacters(in: .whitespacesAndNewlines)
        if activity == nil, !text.isEmpty, saveCustom, !screen.isPreview {
            let saved = BreakActivity(title: text, symbol: "sparkles")
            store.upsert(saved)
            activity = saved
        }
        screen.startBreak(with: activity, customTitle: text)
    }

    private func tile(_ activity: BreakActivity) -> some View {
        let selected = selectedID == activity.id
        let target = BreakActivities.target(activity.opens)
        let today = store.timesToday(activity)
        return Button { selectedID = selected ? nil : activity.id; custom = "" } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top) {
                    Image(systemName: activity.symbol).font(.system(size: 26, weight: .light)).foregroundStyle(tint)
                        .frame(height: 30)
                    Spacer()
                    if selected {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(tint)
                    } else if activity.id == suggestion?.id {
                        Text("Suggested").font(.caption2.weight(.semibold)).padding(.horizontal, 7).padding(.vertical, 3)
                            .background(tint.opacity(0.18), in: Capsule()).foregroundStyle(tint)
                    }
                }
                Text(activity.title).font(.system(size: 16, weight: .semibold)).lineLimit(2)
                if !activity.note.isEmpty {
                    Text(activity.note).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer(minLength: 0)
                HStack(spacing: 10) {
                    if let minutes = activity.minutes { Label("\(minutes) min", systemImage: "timer") }
                    if let target { Label(BreakActivities.targetName(target), systemImage: "arrow.up.forward.app").lineLimit(1) }
                    if today > 0 { Text("\(today)× today") }
                }
                .font(.caption2).foregroundStyle(.secondary)
            }
            .padding(16).frame(maxWidth: .infinity, minHeight: 138, alignment: .topLeading)
            .background(selected ? tint.opacity(0.2) : surface.opacity(0.06), in: RoundedRectangle(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18).stroke(selected ? tint : surface.opacity(0.12), lineWidth: selected ? 2 : 1))
            .contentShape(RoundedRectangle(cornerRadius: 18))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(activity.note.isEmpty ? activity.title : "\(activity.title), \(activity.note)")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    // MARK: During the break

    private var doing: some View {
        VStack(spacing: 22) {
            if let current = store.current {
                Image(systemName: store.symbol(for: current)).font(.system(size: 64, weight: .light)).foregroundStyle(tint)
                    .frame(width: 130, height: 130).background(tint.opacity(0.12), in: Circle())
            }
            HStack(spacing: 14) {
                Button(action: screen.skipBreak) {
                    Text("End break now").font(.system(size: 14, weight: .medium)).padding(.horizontal, 22).frame(height: 46)
                        .background(surface.opacity(0.08), in: Capsule())
                }
                .buttonStyle(.plain)
                Button { screen.close() } label: {
                    Text("Hide").font(.system(size: 15, weight: .semibold)).padding(.horizontal, 28).frame(height: 46)
                        .background(tint, in: Capsule()).foregroundStyle(onAccent)
                }
                .buttonStyle(.plain).keyboardShortcut(.defaultAction).help("The break keeps running")
            }
        }
    }

    // MARK: Back to focus

    private var backToFocus: some View {
        let running = model.isPomodoroRunning && !screen.isPreview
        return HStack(spacing: 14) {
            Button { screen.extendBreak() } label: {
                Text("5 more minutes").font(.system(size: 14, weight: .medium)).padding(.horizontal, 22).frame(height: 46)
                    .background(surface.opacity(0.08), in: Capsule())
            }
            .buttonStyle(.plain)
            Button(action: screen.startFocus) {
                Label(running ? "Let's go" : "Start focus", systemImage: "brain.head.profile").font(.system(size: 15, weight: .semibold))
                    .padding(.horizontal, 28).frame(height: 46).background(tint, in: Capsule()).foregroundStyle(onAccent)
            }
            .buttonStyle(.plain).keyboardShortcut(.defaultAction)
        }
    }
}

/// The countdown on the break screen. The only part that redraws every second, so clicks elsewhere are never interrupted.
private struct BreakClock: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var countdown = Countdown.shared
    let moment: BreakScreen.Moment
    let isPreview: Bool
    let tint: Color
    let previewMinutes: Int

    var body: some View {
        let running = model.isPomodoroRunning && !isPreview
        let status: String
        switch moment {
        case .breakStarting, .duringBreak: status = running ? "Break in progress" : "Your break starts when you're ready"
        case .backToFocus: status = running ? "Focus started" : "Focus starts when you're ready"
        }
        let time = isPreview ? String(format: "%02d:00", previewMinutes) : model.pomodoroTimeText
        return VStack(spacing: 8) {
            Text(time)
                .font(.system(size: 92, weight: .ultraLight, design: .rounded).monospacedDigit())
                .accessibilityLabel("Time remaining \(time)")
            Capsule().fill(surface.opacity(0.1)).frame(width: 260, height: 4)
                .overlay(alignment: .leading) {
                    Capsule().fill(tint).frame(width: 260 * (isPreview ? 0 : model.pomodoroProgress), height: 4)
                }
                .accessibilityHidden(true)
            Text(status).font(.caption.weight(.semibold)).tracking(1).textCase(.uppercase).foregroundStyle(.secondary)
        }
    }
}
