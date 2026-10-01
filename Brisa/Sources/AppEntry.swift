import SwiftUI
import AppKit

@MainActor
enum BrisaWindowActions {
    static func moveToMenuBar() {
        for window in NSApp.windows where window.title == "Brisa" {
            window.orderOut(nil)
        }
        NSApp.setActivationPolicy(.accessory)
    }

    static func showInDock() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
}

final class BrisaAppDelegate: NSObject, NSApplicationDelegate {
    var playbackAction: (() -> Void)?
    private var pendingPlaybackActions = 0

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where url.scheme == "brisa" && url.host == "playback" && url.path == "/toggle" {
            if let playbackAction { playbackAction() }
            else { pendingPlaybackActions += 1 }
        }
        // A shared mix, from a `.brisamix` file or a `brisa://mix?d=…` link. It is validated, then the user confirms.
        for url in urls {
            let shared: SharedMix?
            if url.isFileURL, url.pathExtension.lowercased() == MixSharing.fileExtension {
                shared = (try? Data(contentsOf: url)).flatMap { MixSharing.decode(data: $0) }
            } else if url.scheme == "brisa", url.host == "mix" {
                shared = MixSharing.decode(link: url)
            } else { continue }
            Task { @MainActor in
                BrisaWindowActions.showInDock()
                NotificationCenter.default.post(name: Notification.Name("BrisaShowWindow"), object: nil)
                if let shared { AppModel.shared.pendingSharedMix = shared }
                else { NSSound.beep() }
            }
        }
    }

    func connectPlayback(_ action: @escaping () -> Void) {
        playbackAction = action
        let pending = pendingPlaybackActions
        pendingPlaybackActions = 0
        for _ in 0..<pending { action() }
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        BrisaWindowActions.showInDock()
        NotificationCenter.default.post(name: Notification.Name("BrisaShowWindow"), object: nil)
        return true
    }
}

struct BrisaApp: App {
    @NSApplicationDelegateAdaptor(BrisaAppDelegate.self) private var delegate
    @StateObject private var model = AppModel.shared

    var body: some Scene {
        Window("Brisa", id: "main") {
            BrisaMainView(model: model)
                .onAppear { delegate.connectPlayback { model.togglePlayback() }; BrisaDesktopPlayer.shared.restore(); BrisaPomodoroWidget.shared.restore() }
        }
            .windowStyle(.hiddenTitleBar)
            .defaultSize(width: 1080, height: 770)
            .commands {
                CommandGroup(replacing: .appSettings) {
                    Button("Settings…") { NotificationCenter.default.post(name: Notification.Name("BrisaShowSettings"), object: nil) }
                        .keyboardShortcut(",")
                }
                // ⌘Q quits, like any Mac app. Closing the window (⌘W) keeps Brisa running in the menu bar.
                CommandGroup(replacing: .appTermination) {
                    Button("Keep Running in Menu Bar") { BrisaWindowActions.moveToMenuBar() }
                    Button("Quit Brisa") { NSApp.terminate(nil) }
                        .keyboardShortcut("q")
                }
            }
        MenuBarExtra {
            MenuBarPlayerView(model: model)
        } label: {
            MenuBarLabel(model: model)
        }
        .menuBarExtraStyle(.window)
    }
}

/// While a Pomodoro is running (or paused mid-phase) the menu bar shows the countdown instead of the Brisa icon.
private struct MenuBarLabel: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var countdown = Countdown.shared
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Group {
            if model.isPomodoroRunning || model.pomodoroRemainingSeconds < model.pomodoroTotalSeconds {
                Label(model.pomodoroTimeText, systemImage: model.isPomodoroRunning ? model.pomodoroPhase.symbol : "pause.fill")
                    .labelStyle(.titleAndIcon).monospacedDigit()
            } else {
                Image(systemName: "wind")
            }
        }
        // The menu bar icon lives while the main window is closed, so it can reopen it (the window's own listener is gone then).
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("BrisaShowWindow"))) { _ in
            guard !NSApp.windows.contains(where: { $0.title == "Brisa" && $0.isVisible }) else { return }
            openWindow(id: "main")
        }
    }
}

private struct BrisaMainView: View {
    @ObservedObject var model: AppModel
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        ContentView(model: model)
            .onDisappear { BrisaWindowActions.moveToMenuBar() }
            .onReceive(NotificationCenter.default.publisher(for: Notification.Name("BrisaShowWindow"))) { _ in
                openWindow(id: "main")
                BrisaWindowActions.showInDock()
            }
    }
}

// A single live panel shares the main player's model and audio engine.
@MainActor
final class BrisaDesktopPlayer: NSObject, ObservableObject, NSWindowDelegate {
    static let shared = BrisaDesktopPlayer()
    private var panel: NSPanel?
    private var dragStart: (mouse: NSPoint, origin: NSPoint)?

    func dragFromSurface() {
        guard !locked, let panel else { return }
        let mouse = NSEvent.mouseLocation
        if dragStart == nil { dragStart = (mouse, panel.frame.origin) }
        guard let start = dragStart else { return }
        panel.setFrameOrigin(NSPoint(x: start.origin.x + mouse.x - start.mouse.x,
                                     y: start.origin.y + mouse.y - start.mouse.y))
    }

    func endSurfaceDrag() { dragStart = nil }
    @Published var enabled = UserDefaults.standard.bool(forKey: "mini.enabled") {
        didSet { UserDefaults.standard.set(enabled, forKey: "mini.enabled"); if enabled { show() } else { panel?.orderOut(nil) } }
    }
    @Published var aboveApps = UserDefaults.standard.bool(forKey: "mini.aboveApps") {
        didSet { UserDefaults.standard.set(aboveApps, forKey: "mini.aboveApps"); applyPlacement() }
    }
    @Published var locked = UserDefaults.standard.bool(forKey: "mini.locked") {
        didSet { UserDefaults.standard.set(locked, forKey: "mini.locked"); panel?.isMovableByWindowBackground = false }
    }

    func addToDesktop() {
        locked = false
        aboveApps = false
        show()
        BrisaWindowActions.moveToMenuBar()
        // Reveal the desktop using macOS Mission Control.
        let url = URL(fileURLWithPath: "/System/Applications/Mission Control.app")
        let config = NSWorkspace.OpenConfiguration()
        config.arguments = ["--show-desktop"]
        NSWorkspace.shared.openApplication(at: url, configuration: config) { _, _ in }
    }

    func restore() { if enabled { show() } }
    private func applyPlacement() {
        panel?.level = aboveApps ? .floating : NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
        panel?.collectionBehavior = aboveApps ? [.canJoinAllSpaces, .fullScreenAuxiliary] : [.canJoinAllSpaces, .stationary]
    }
    func windowDidMove(_ notification: Notification) {
        guard let panel else { return }
        UserDefaults.standard.set(NSStringFromRect(panel.frame), forKey: "mini.frame")
    }

    func show() {
        if !enabled { enabled = true; return }
        if let panel { applyPlacement(); panel.orderFrontRegardless(); return }
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 380, height: 240),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = "Brisa Mini Player"
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = false
        panel.hidesOnDeactivate = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = NSHostingView(rootView: LiveBrisaPlayer(model: .shared))
        panel.center()
        if let saved = UserDefaults.standard.string(forKey: "mini.frame") {
            let frame = NSRectFromString(saved)
            if NSScreen.screens.contains(where: { $0.visibleFrame.contains(frame) }) {
                panel.setFrame(frame, display: false)
            }
        }
        self.panel = panel
        panel.delegate = self
        applyPlacement()
        panel.orderFrontRegardless()
    }

    func hide() { enabled = false }
}

private struct PlayerWaves: View {
    let paused: Bool
    let color: Color
    let heldPhase: Double
    let animationStart: Date?
    @Binding var lastRenderedPhase: Double

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: paused)) { timeline in
            let phase = currentPhase(at: timeline.date)
            Canvas { context, size in
                for layer in 0..<22 {
                    context.stroke(wavePath(layer: layer, phase: phase, size: size),
                                   with: .color(color.opacity(0.38)), lineWidth: 0.6)
                }
            }
            .onChange(of: timeline.date) { _ in lastRenderedPhase = phase }
        }
    }

    private func currentPhase(at date: Date) -> Double {
        guard let start = animationStart else { return heldPhase }
        return heldPhase + max(0, date.timeIntervalSince(start)) * 0.65
    }

    private func wavePath(layer: Int, phase: Double, size: CGSize) -> Path {
        var path = Path()
        let offset = Double(layer)
        for step in 0...100 {
            let t = Double(step) / 100
            let wave: Double = sin(t * .pi * 3.5 + phase + offset * 0.06)
            let second: Double = sin(t * .pi * 6 - phase * 0.6 + offset * 0.12)
            let y: Double = size.height * (0.5 + wave * 0.21 + second * 0.09) + offset * 0.5
            let point = CGPoint(x: t * size.width, y: y)
            if step == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        return path
    }
}

private struct LiveBrisaPlayer: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var desktop = BrisaDesktopPlayer.shared
    @ObservedObject private var countdown = Countdown.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var heldPhase = 0.0
    @State private var lastRenderedPhase = 0.0
    @State private var animationStart: Date?
    @ObservedObject private var themeStore = BrisaThemeStore.shared
    private var mint: Color { themeStore.current.accent }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 26).fill(.ultraThinMaterial)
            RoundedRectangle(cornerRadius: 26)
                .fill(LinearGradient(colors: [mint.opacity(0.14), themeStore.current.shade],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
            PlayerWaves(paused: !model.isPlaying || reduceMotion, color: mint,
                        heldPhase: heldPhase, animationStart: animationStart,
                        lastRenderedPhase: $lastRenderedPhase)
                .frame(height: 90).offset(y: 24).allowsHitTesting(false)
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label("brisa", systemImage: "wind").font(.system(size: 18, weight: .medium, design: .rounded))
                    Spacer()
                    Text(model.isPlaying ? "PLAYING" : "PAUSED").font(.system(size: 9, weight: .medium)).tracking(1)
                    Button { desktop.aboveApps.toggle() } label: {
                        Image(systemName: desktop.aboveApps ? "pin.fill" : "pin").frame(width: 22, height: 24)
                    }.buttonStyle(.plain).help(desktop.aboveApps ? "Keep on desktop" : "Keep above apps")
                    Button { desktop.locked.toggle() } label: {
                        Image(systemName: desktop.locked ? "lock.fill" : "lock.open").frame(width: 22, height: 24)
                    }.buttonStyle(.plain).help(desktop.locked ? "Unlock position" : "Lock position")
                    Button { BrisaDesktopPlayer.shared.hide() } label: {
                        Image(systemName: "xmark").font(.system(size: 10)).frame(width: 24, height: 24)
                    }.buttonStyle(.plain).accessibilityLabel("Close mini player")
                }.foregroundStyle(mint)
                Menu {
                    ForEach(["Noise", "Water", "Nature", "Spaces", "Tones", "Imported"], id: \.self) { category in
                        Menu(category) {
                            ForEach(model.availableLibrary.filter { $0.category == category }) { sound in
                                Button { model.replaceWith(sound) } label: { Label(sound.name, systemImage: sound.icon) }
                            }
                        }
                    }
                    if !model.mixes.isEmpty {
                        Divider()
                        Menu("My mixes") {
                            ForEach(model.mixes) { mix in
                                Button(mix.name) { model.applyMix(mix) }
                            }
                        }
                    }
                } label: {
                    HStack {
                        Text(model.nowPlayingTitle).font(.system(size: 24, weight: .regular, design: .rounded)).lineLimit(1)
                        Image(systemName: "chevron.down").font(.caption)
                    }
                }.menuStyle(.borderlessButton).help("Choose a sound or saved mix")
                if model.isPomodoroRunning || model.pomodoroRemainingSeconds < model.pomodoroTotalSeconds {
                    Label("\(model.pomodoroPhase.title) · \(model.pomodoroTimeText)", systemImage: model.isPomodoroRunning ? "timer" : "pause.fill")
                        .font(.caption.monospacedDigit()).foregroundStyle(mint)
                } else {
                    Text("Your quiet space").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                HStack(spacing: 12) {
                    Button { model.toggleMute() } label: {
                        Image(systemName: model.masterVolume == 0 ? "speaker.slash" : "speaker.wave.2")
                    }.buttonStyle(.plain).accessibilityLabel("Toggle mute")
                    Slider(value: $model.masterVolume, in: 0...1)
                        .onChange(of: model.masterVolume) { _ in model.synchronizeAudio() }
                        .accessibilityLabel("Volume")
                    Text("\(Int(model.masterVolume * 100))%").font(.caption.monospacedDigit()).frame(width: 32)
                    Button { model.togglePlayback() } label: {
                        Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 20)).frame(width: 52, height: 52)
                            .background(surface.opacity(0.12), in: Circle())
                            .overlay(Circle().strokeBorder(mint.opacity(0.5), lineWidth: 1))
                    }.buttonStyle(.plain).accessibilityLabel(model.isPlaying ? "Pause" : "Play")
                }
            }.padding(22)
        }
        .overlay(RoundedRectangle(cornerRadius: 26).strokeBorder(
            LinearGradient(colors: [surface.opacity(themeStore.current == .light ? 0.25 : 0.5), .clear, mint.opacity(0.5)],
                           startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 26))
        .frame(width: 380, height: 240).preferredColorScheme(themeStore.current.scheme).tint(mint)
        .coordinateSpace(name: "miniSurface")
        .onAppear { if model.isPlaying && !reduceMotion { animationStart = .now } }
        .onChange(of: model.isPlaying && !reduceMotion) { running in
            heldPhase = lastRenderedPhase
            animationStart = running ? .now : nil
        }
        .simultaneousGesture(DragGesture(minimumDistance: 8, coordinateSpace: .named("miniSurface"))
            .onChanged { gesture in
                // The panel is 240 pt tall. Reserve the entire bottom control
                // strip, including the slider's thumb and native hit padding.
                // Check the start point so leaving the slider mid-drag cannot
                // turn a volume gesture into a window drag.
                guard gesture.startLocation.y < 158 else { return }
                desktop.dragFromSurface()
            }
            .onEnded { _ in desktop.endSurfaceDrag() })
    }
}




struct BrisaWidgetSettings: View {
    private enum Tab: String, CaseIterable, Identifiable {
        case appearance = "Appearance", widgets = "Widgets", general = "General"
        var id: String { rawValue }
    }

    @Environment(\.dismiss) private var dismiss
    @ObservedObject var model: AppModel
    @ObservedObject private var themes = BrisaThemeStore.shared
    @ObservedObject private var miniPlayer = BrisaDesktopPlayer.shared
    @ObservedObject private var pomodoroWidget = BrisaPomodoroWidget.shared
    @ObservedObject private var videoPlayer = YouTubeVideoPlayer.shared
    @State private var tab = Tab.appearance
    @State private var launchAtLogin = LaunchAtLogin.isEnabled
    @State private var launchMessage: String?

    private var hasPendingPreview: Bool { themes.preview != nil && themes.preview != themes.selected }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("Settings").font(.title2.bold())
                Spacer()
                Button("Done") { themes.cancelPreview(); dismiss() }
            }
            Picker("", selection: $tab) {
                ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden()
            ScrollView {
                switch tab {
                case .appearance: appearance
                case .widgets: widgets
                case .general: general
                }
            }
            .id(tab)
        }
        .padding(32)
        .frame(width: 470, height: 720)
        .background(themes.current.background[1].opacity(0.001))
        .preferredColorScheme(themes.current.scheme)
        .tint(themes.current.accent)
        .onDisappear { themes.cancelPreview() }
    }

    // MARK: General

    private var general: some View {
        VStack(alignment: .leading, spacing: 14) {
            settingRow(symbol: "power", title: "Open Brisa at login",
                       detail: "Start in the menu bar when you sign in, so your widgets are always there.") {
                Toggle("", isOn: Binding(get: { launchAtLogin }, set: setLaunchAtLogin)).labelsHidden().toggleStyle(.switch)
            }
            if let launchMessage {
                Text(launchMessage).font(.caption).foregroundStyle(.orange)
            }
            settingRow(symbol: "moon.zzz", title: "Pause sounds when the Mac sleeps",
                       detail: "Playback stops when the lid closes and picks up again on wake, on whichever speakers or headphones are connected.") {
                Toggle("", isOn: $model.pausesOnSleep).labelsHidden().toggleStyle(.switch)
            }
            settingRow(symbol: "waveform.path", title: "Crossfade between mixes",
                       detail: "Sounds fade in and out when you switch mixes instead of cutting. Turn off for instant changes.") {
                Toggle("", isOn: $model.crossfadeEnabled).labelsHidden().toggleStyle(.switch)
            }
            settingRow(symbol: "water.waves", title: "Living mix",
                       detail: "Each sound's volume drifts slowly up and down, so long sessions feel less static. Also on the player.") {
                Toggle("", isOn: $model.livingMixEnabled).labelsHidden().toggleStyle(.switch)
            }
            if model.livingMixEnabled {
                Picker("How much sounds move", selection: $model.livingMixIntensity) {
                    ForEach(LivingMix.Intensity.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16)
            }
            settingRow(symbol: "play.rectangle", title: "Small video window",
                       detail: "YouTube videos play in a compact window that stays visible but out of the way. YouTube requires the video to stay on screen while it plays.") {
                Toggle("", isOn: $videoPlayer.compact).labelsHidden().toggleStyle(.switch)
            }
            settingRow(symbol: "keyboard", title: "Media keys and Control Center",
                       detail: "Play and pause from your keyboard, AirPods or the Now Playing menu. Always on.") {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(themes.current.accent)
            }
            if BrisaIntegration.isAvailable {
                settingRow(symbol: "square.2.layers.3d", title: "Shortcuts and Focus",
                           detail: "Play a mix or sound, pause, set the volume or start a focus session from the Shortcuts app, Siri or Spotlight. To play a mix when a Focus turns on, pick the Focus in System Settings and add Brisa under Focus filters. Brisa stops it again when the Focus ends.") {
                    Button("Focus…") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.Focus-Settings.extension") { NSWorkspace.shared.open(url) }
                    }
                    .help("Open Focus settings")
                }
            }
            settingRow(symbol: "headphones", title: "Audio output changes",
                       detail: "If you unplug headphones or switch devices, Brisa recovers on its own. Always on.") {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(themes.current.accent)
            }
        }
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            try LaunchAtLogin.set(enabled)
            launchMessage = LaunchAtLogin.status == .requiresApproval
                ? "Approve Brisa in System Settings → General → Login Items to finish." : nil
        } catch {
            launchMessage = "Couldn't change this: \(error.localizedDescription)"
        }
        launchAtLogin = LaunchAtLogin.isEnabled
    }

    private func settingRow<Trailing: View>(symbol: String, title: String, detail: String, @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol).font(.title3).frame(width: 26).foregroundStyle(themes.current.accent)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline)
                Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            trailing()
        }
        .padding(16)
        .background(surface.opacity(0.05), in: RoundedRectangle(cornerRadius: 18))
    }

    // MARK: Widgets

    private var widgets: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Add Brisa to your desktop. Drag a widget anywhere to place it; pin and lock controls live on each widget.")
                .font(.caption).foregroundStyle(.secondary)
            widgetCard(title: "Mini player", symbol: "waveform", detail: "Play, pause and switch sounds without opening Brisa.",
                       isOn: miniPlayer.enabled, previewSize: CGSize(width: 380, height: 240),
                       add: {
                           themes.cancelPreview()
                           dismiss()
                           DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { BrisaDesktopPlayer.shared.addToDesktop() }
                       },
                       remove: { miniPlayer.hide() }) {
                LiveBrisaPlayer(model: model)
            }
            widgetCard(title: "Pomodoro", symbol: "timer", detail: "A focus timer with start, pause and skip, and your current task.",
                       isOn: pomodoroWidget.enabled, previewSize: CGSize(width: 240, height: 284),
                       add: { pomodoroWidget.enabled = true },
                       remove: { pomodoroWidget.hide() }) {
                PomodoroWidgetView(model: model)
            }
        }
    }

    private func widgetCard<Preview: View>(title: String, symbol: String, detail: String, isOn: Bool, previewSize: CGSize,
                                           add: @escaping () -> Void, remove: @escaping () -> Void,
                                           @ViewBuilder preview: () -> Preview) -> some View {
        let scale = min(1, 0.8 * 406 / previewSize.width, 250 / previewSize.height)
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Label(title, systemImage: symbol).font(.headline)
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if isOn {
                    Label("On desktop", systemImage: "checkmark.circle.fill").font(.caption.weight(.medium))
                        .foregroundStyle(themes.current.accent)
                }
            }
            preview()
                .allowsHitTesting(false).accessibilityHidden(true)
                .scaleEffect(scale)
                .frame(width: previewSize.width * scale, height: previewSize.height * scale)
                .frame(maxWidth: .infinity)
            HStack {
                Spacer()
                if isOn {
                    Button(role: .destructive, action: remove) { Label("Remove from desktop", systemImage: "minus.circle") }
                } else {
                    Button(action: add) { Label("Add to desktop", systemImage: "plus.circle.fill") }
                        .buttonStyle(.borderedProminent)
                }
            }
        }
        .padding(16)
        .background(surface.opacity(0.05), in: RoundedRectangle(cornerRadius: 18))
    }

    private var appearance: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Appearance", systemImage: "paintpalette").font(.headline)
            Text("Pick a theme to preview it across the app and the mini player, then apply it.")
                .font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 10) {
                ForEach(BrisaTheme.allCases) { theme in
                    let isApplied = themes.selected == theme
                    let isShown = themes.current == theme
                    Button { withAnimation(.easeInOut(duration: 0.2)) { themes.preview = theme == themes.selected ? nil : theme } } label: {
                        VStack(spacing: 6) {
                            ZStack {
                                RoundedRectangle(cornerRadius: 10)
                                    .fill(LinearGradient(colors: theme.background, startPoint: .topLeading, endPoint: .bottomTrailing))
                                Circle().fill(theme.accent).frame(width: 16, height: 16)
                            }
                            .frame(height: 46)
                            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(isShown ? theme.accent : Color.gray.opacity(0.35), lineWidth: isShown ? 2 : 1))
                            Text(theme.name).font(.caption.weight(isShown ? .semibold : .regular))
                            Image(systemName: isApplied ? "checkmark.circle.fill" : "circle").font(.caption2)
                                .foregroundStyle(isApplied ? themes.current.accent : .secondary).opacity(isApplied ? 1 : 0.4)
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(theme.name) theme\(isApplied ? ", applied" : "")")
                }
            }
            if hasPendingPreview, let preview = themes.preview {
                HStack {
                    Text("Previewing \(preview.name)").font(.caption.weight(.medium)).foregroundStyle(.secondary)
                    Spacer()
                    Button("Cancel") { withAnimation { themes.cancelPreview() } }
                    Button("Apply") { withAnimation { themes.apply(preview) } }.keyboardShortcut(.defaultAction)
                }
            }
        }
    }
}
