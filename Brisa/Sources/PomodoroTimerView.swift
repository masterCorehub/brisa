import SwiftUI

/// Full-page Pomodoro: a timer hero on the left, today's progress, history and settings on the right.
struct PomodoroTimerView: View {
    @ObservedObject private var themeStore = BrisaThemeStore.shared
    @ObservedObject private var widget = BrisaPomodoroWidget.shared
    @ObservedObject var model: AppModel
    @ObservedObject private var countdown = Countdown.shared
    @ObservedObject private var breaks = BreakStore.shared
    @State private var confirmClear = false
    @State private var showSettings = false
    @State private var editingTime = false
    @State private var newTask = ""
    @State private var renamingTaskID: UUID?
    @State private var renameText = ""
    @FocusState private var renameFocused: Bool
    @State private var minutesInput = ""

    private var phaseColor: Color { themeStore.current.color(for: model.pomodoroPhase) }

    var body: some View {
        // The timer stays put; only the sidebar on the right scrolls.
        GeometryReader { geo in
            HStack(alignment: .top, spacing: 22) {
                timerHero(ring: min(290, max(170, geo.size.height - 290)))
                    .frame(minWidth: 400, maxHeight: geo.size.height - 4)
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 16) {
                        tasksCard
                        soundCard
                        BreakScreenCard(model: model)
                        todayCard
                        weekCard
                        historyCard
                        settingsCard
                    }
                }
                .frame(width: 340)
            }
            .padding(.horizontal, 34).padding(.bottom, 18).padding(.top, 4)
        }
        .confirmationDialog("Delete all Pomodoro history?", isPresented: $confirmClear) {
            Button("Delete history", role: .destructive) { model.clearPomodoroHistory() }
        }
    }

    // MARK: Hero

    private func timerHero(ring: CGFloat) -> some View {
        VStack(spacing: 22) {
            HStack(spacing: 6) {
                ForEach(PomodoroPhase.allCases, id: \.self) { phase in
                    Button { withAnimation(.easeInOut(duration: 0.2)) { model.selectPomodoroPhase(phase) } } label: {
                        Label(phase.title, systemImage: phase.symbol)
                            .font(.system(size: 12, weight: .medium)).padding(.horizontal, 13).padding(.vertical, 8)
                            .background(model.pomodoroPhase == phase ? phaseColor : surface.opacity(0.07), in: Capsule())
                            .foregroundStyle(model.pomodoroPhase == phase ? onAccent : .primary)
                    }
                    .buttonStyle(.plain).disabled(model.isPomodoroRunning && model.pomodoroPhase != phase)
                }
            }

            ZStack {
                Circle().fill(phaseColor.opacity(model.isPomodoroRunning ? 0.16 : 0.08)).blur(radius: 50).frame(width: ring + 10, height: ring + 10)
                Circle().stroke(surface.opacity(0.07), lineWidth: 12)
                Circle().trim(from: 0, to: model.pomodoroProgress)
                    .stroke(phaseColor, style: StrokeStyle(lineWidth: 12, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.linear(duration: 0.4), value: model.pomodoroProgress)
                VStack(spacing: 6) {
                    Button {
                        minutesInput = "\(model.pomodoroTotalSeconds / 60)"
                        editingTime = true
                    } label: {
                        Text(model.pomodoroTimeText)
                            .font(.system(size: ring * 0.262, weight: .light, design: .rounded).monospacedDigit())
                    }
                    .buttonStyle(.plain).help("Click to set the time")
                    .accessibilityLabel("Time remaining \(model.pomodoroTimeText). Click to change.")
                    .popover(isPresented: $editingTime, arrowEdge: .bottom) { timeEditor }
                    Text(model.isPomodoroRunning ? "In progress" : "Ready")
                        .font(.caption.weight(.bold)).tracking(1.6).textCase(.uppercase).foregroundStyle(.secondary)
                    HStack(spacing: 7) {
                        ForEach(0..<model.longBreakInterval, id: \.self) { index in
                            Circle().fill(index < model.pomodoroCycleProgress ? phaseColor : surface.opacity(0.15)).frame(width: 8, height: 8)
                        }
                    }
                    .padding(.top, 8)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(model.pomodoroCycleProgress) of \(model.longBreakInterval) sessions before long break")
                }
            }
            .frame(width: ring, height: ring)

            activeTaskChip

            HStack(spacing: 12) {
                roundButton("arrow.counterclockwise", "Reset") { model.resetPomodoro() }
                roundButton("minus", "Remove 5 minutes") { model.extendPomodoro(minutes: -5) }
                Button { model.isPomodoroRunning ? model.pausePomodoro() : model.startPomodoro() } label: {
                    Label(model.isPomodoroRunning ? "Pause" : "Start", systemImage: model.isPomodoroRunning ? "pause.fill" : "play.fill")
                        .font(.system(size: 16, weight: .semibold))
                        .frame(width: 120, height: 46).background(phaseColor, in: Capsule())
                        .foregroundStyle(onAccent)
                }
                .buttonStyle(.plain)
                roundButton("forward.fill", "Skip phase") { model.skipPomodoro() }
                roundButton("plus", "Add 5 minutes") { model.extendPomodoro() }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity).padding(.vertical, 22).padding(.horizontal, 20)
        .background(surface.opacity(0.04), in: RoundedRectangle(cornerRadius: 22))
        .overlay(alignment: .topTrailing) {
            Button { widget.enabled.toggle() } label: {
                Image(systemName: widget.enabled ? "macwindow.badge.plus" : "macwindow")
                    .font(.system(size: 13, weight: .medium)).frame(width: 32, height: 32)
                    .background(surface.opacity(widget.enabled ? 0.16 : 0.07), in: Circle())
                    .foregroundStyle(widget.enabled ? phaseColor : .secondary)
            }
            .buttonStyle(.plain).padding(14)
            .help(widget.enabled ? "Hide the desktop widget" : "Show a Pomodoro widget on the desktop")
            .accessibilityLabel(widget.enabled ? "Hide desktop widget" : "Show desktop widget")
        }
    }

    private var activeTaskChip: some View {
        HStack(spacing: 8) {
            if model.pomodoroPhase != .work, let doing = breaks.current {
                Image(systemName: breaks.symbol(for: doing)).foregroundStyle(phaseColor)
                Text("Break: \(doing.title)").lineLimit(1)
            } else if let task = model.activePomodoroTask {
                Image(systemName: "target").foregroundStyle(phaseColor)
                Text(task.title).lineLimit(1)
                Text("\(task.completedSessions)/\(task.estimate)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            } else {
                Image(systemName: "scope").foregroundStyle(phaseColor)
                Text("No task selected — pick or add one below").foregroundStyle(.secondary)
            }
        }
        .font(.system(size: 13, weight: .medium))
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(surface.opacity(0.06), in: Capsule()).frame(maxWidth: 380)
        .accessibilityElement(children: .combine)
    }

    private var tasksCard: some View {
        let open = model.pomodoroTasks.filter { !$0.isDone }
        let done = model.pomodoroTasks.filter { $0.isDone }
        let planned = open.reduce(0) { $0 + max($1.estimate - $1.completedSessions, 0) }
        return card("Tasks", trailing: {
            if !open.isEmpty {
                Text("\(planned) session\(planned == 1 ? "" : "s") left").font(.caption).foregroundStyle(.secondary)
            }
        }) {
            HStack(spacing: 8) {
                Button { model.addPomodoroTask(newTask); newTask = "" } label: {
                    Image(systemName: "plus.circle.fill").foregroundStyle(newTask.trimmingCharacters(in: .whitespaces).isEmpty ? .secondary : phaseColor)
                }
                .buttonStyle(.plain).accessibilityLabel("Add task")
                TextField("Add a task and press Return", text: $newTask).textFieldStyle(.plain)
                    .onSubmit { model.addPomodoroTask(newTask); newTask = "" }
                    .accessibilityLabel("New task")
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .background(surface.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))

            if model.pomodoroTasks.isEmpty {
                Text("Break your work into tasks, estimate how many focus sessions each needs, and Brisa keeps count as you go.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            VStack(spacing: 6) {
                ForEach(open) { taskRow($0) }
            }
            if !done.isEmpty {
                HStack {
                    Text("Completed · \(done.count)").font(.caption.weight(.bold)).tracking(1).textCase(.uppercase).foregroundStyle(.secondary)
                    Spacer()
                    Button("Clear") { withAnimation { model.clearCompletedPomodoroTasks() } }
                        .buttonStyle(.plain).font(.caption).foregroundStyle(.secondary)
                }
                .padding(.top, 4)
                VStack(spacing: 6) {
                    ForEach(done) { taskRow($0) }
                }
            }
        }
    }

    private func taskRow(_ task: PomodoroTask) -> some View {
        let isActive = model.activePomodoroTaskID == task.id
        return HStack(spacing: 10) {
            Button { withAnimation(.easeInOut(duration: 0.2)) { model.togglePomodoroTaskDone(task.id) } } label: {
                Image(systemName: task.isDone ? "checkmark.circle.fill" : "circle").font(.system(size: 18))
                    .foregroundStyle(task.isDone ? phaseColor : .secondary)
            }
            .buttonStyle(.plain).accessibilityLabel(task.isDone ? "Mark \(task.title) as not done" : "Mark \(task.title) as done")

            if renamingTaskID == task.id {
                TextField("Task name", text: $renameText).textFieldStyle(.plain)
                    .focused($renameFocused)
                    .onSubmit { commitRename(task.id) }
                    .onExitCommand { renamingTaskID = nil }
                    .accessibilityLabel("Rename \(task.title)")
            } else {
                Button { model.selectPomodoroTask(isActive ? nil : task.id) } label: {
                    Text(task.title).strikethrough(task.isDone).lineLimit(1)
                        .foregroundStyle(task.isDone ? .secondary : .primary)
                        .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                }
                .buttonStyle(.plain).disabled(task.isDone)
                .simultaneousGesture(TapGesture(count: 2).onEnded { if !task.isDone { beginRename(task) } })
                .help(isActive ? "Stop working on this task" : "Work on this task · double-click to rename")
            }

            if isActive { Text("Now").font(.caption2.weight(.bold)).foregroundStyle(phaseColor) }

            Menu {
                ForEach(1...8, id: \.self) { count in
                    Button("\(count) session\(count == 1 ? "" : "s")") { model.setPomodoroTaskEstimate(task.id, count) }
                }
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: "timer").font(.caption2)
                    Text("\(task.completedSessions)/\(task.estimate)").font(.caption.monospacedDigit())
                }
                .foregroundStyle(task.completedSessions >= task.estimate ? phaseColor : .secondary)
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help("Estimated focus sessions")

            Button { withAnimation { model.removePomodoroTask(task.id) } } label: { Image(systemName: "xmark").font(.caption) }
                .buttonStyle(.plain).foregroundStyle(.tertiary).accessibilityLabel("Delete \(task.title)")
        }
        .font(.callout)
        .padding(.horizontal, 12).padding(.vertical, 9)
        .background(isActive ? phaseColor.opacity(0.14) : surface.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(isActive ? phaseColor.opacity(0.5) : .clear, lineWidth: 1))
        .contextMenu {
            if !task.isDone {
                Button { beginRename(task) } label: { Label("Rename", systemImage: "pencil") }
                Button { withAnimation { model.movePomodoroTask(task.id, by: -1) } } label: { Label("Move up", systemImage: "arrow.up") }
                Button { withAnimation { model.movePomodoroTask(task.id, by: 1) } } label: { Label("Move down", systemImage: "arrow.down") }
                Divider()
            }
            Button(role: .destructive) { withAnimation { model.removePomodoroTask(task.id) } } label: { Label("Delete", systemImage: "trash") }
        }
        .draggable(task.id.uuidString)
        .dropDestination(for: String.self) { items, _ in
            guard let raw = items.first, let dragged = UUID(uuidString: raw) else { return false }
            withAnimation { model.movePomodoroTask(dragged, before: task.id) }
            return true
        }
    }

    private func beginRename(_ task: PomodoroTask) {
        renameText = task.title
        renamingTaskID = task.id
        renameFocused = true
    }

    private func commitRename(_ id: UUID) {
        model.renamePomodoroTask(id, to: renameText)
        renamingTaskID = nil
    }

    private var timeEditor: some View {
        let range = model.pomodoroMinutesRange
        func apply() {
            if let value = Int(minutesInput.trimmingCharacters(in: .whitespaces)) { model.setPomodoroMinutes(value) }
            editingTime = false
        }
        return VStack(alignment: .leading, spacing: 12) {
            Text("\(model.pomodoroPhase.title) length").font(.headline)
            HStack(spacing: 6) {
                TextField("min", text: $minutesInput).textFieldStyle(.roundedBorder).frame(width: 64).multilineTextAlignment(.trailing)
                    .onSubmit(apply)
                Text("min").foregroundStyle(.secondary)
                Spacer()
                Button("Set", action: apply).keyboardShortcut(.defaultAction)
            }
            HStack(spacing: 6) {
                ForEach([5, 10, 15, 25, 45, 60].filter { range.contains($0) }, id: \.self) { preset in
                    Button("\(preset)") { model.setPomodoroMinutes(preset); editingTime = false }.buttonStyle(.bordered).controlSize(.small)
                }
            }
            Text("Applies now and becomes the default for this phase.").font(.caption).foregroundStyle(.secondary)
        }
        .padding(16).frame(width: 260)
    }

    private func roundButton(_ symbol: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 15, weight: .medium))
                .frame(width: 46, height: 46).background(surface.opacity(0.08), in: Circle())
        }
        .buttonStyle(.plain).help(label).accessibilityLabel(label)
    }

    // MARK: Cards

    private func card<Content: View>(_ title: String, @ViewBuilder trailing: () -> some View = { EmptyView() }, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(title).font(.caption.weight(.bold)).tracking(1.2).textCase(.uppercase).foregroundStyle(.secondary)
                Spacer()
                trailing()
            }
            content()
        }
        .padding(18).frame(maxWidth: .infinity, alignment: .leading)
        .background(surface.opacity(0.04), in: RoundedRectangle(cornerRadius: 18))
    }

    private var soundCard: some View {
        card("Sound · \(model.pomodoroPhase.title)") {
            VStack(spacing: 6) {
                ForEach(model.pomodoroPhase.presets) { preset in
                    let playing = model.isPomodoroPresetPlaying(preset)
                    Button {
                        if playing { model.isPlaying = false; model.synchronizeAudio() } else { model.applyPomodoroPreset(preset) }
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: preset.icon).frame(width: 22).foregroundStyle(phaseColor)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(preset.name).font(.callout.weight(.medium))
                                Text(preset.detail).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: playing ? "pause.fill" : "play.fill").font(.caption).foregroundStyle(playing ? phaseColor : .secondary)
                        }
                        .padding(.horizontal, 12).padding(.vertical, 8).contentShape(Rectangle())
                        .background(playing ? phaseColor.opacity(0.14) : surface.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(playing ? "Pause" : "Play") \(preset.name)")
                }
            }
            Text(model.changesSoundscapeWithPomodoro ? "Auto-plays the first suggestion (or your pick in Settings) at each phase." : "Turn on “Change soundscape per phase” in Settings to switch automatically.")
                .font(.caption2).foregroundStyle(.tertiary)
        }
    }

    private var todayCard: some View {
        let done = model.pomodoroSessionsToday.count
        return card("Today") {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text("\(done)").font(.system(size: 38, weight: .semibold, design: .rounded).monospacedDigit())
                Text("of \(model.pomodoroDailyGoal) sessions").font(.callout).foregroundStyle(.secondary)
            }
            ProgressView(value: min(Double(done), Double(model.pomodoroDailyGoal)), total: Double(model.pomodoroDailyGoal)).tint(accent)
            HStack {
                miniStat("clock", minutesText(model.focusMinutesToday), "focused")
                Divider().frame(height: 26)
                miniStat("flame.fill", "\(model.pomodoroStreak)", model.pomodoroStreak == 1 ? "day streak" : "day streak")
                Divider().frame(height: 26)
                miniStat("sum", minutesText(model.totalFocusMinutes), "all time")
            }
        }
    }

    private func miniStat(_ symbol: String, _ value: String, _ label: String) -> some View {
        VStack(spacing: 2) {
            Label(value, systemImage: symbol).font(.system(size: 14, weight: .semibold).monospacedDigit()).labelStyle(.titleAndIcon)
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private var weekCard: some View {
        let week = model.pomodoroWeek
        let peak = max(week.map(\.minutes).max() ?? 0, 1)
        return card("Last 7 days") {
            HStack(alignment: .bottom, spacing: 8) {
                ForEach(week, id: \.date) { day in
                    VStack(spacing: 4) {
                        Text(day.minutes > 0 ? "\(day.minutes)" : " ").font(.system(size: 9).monospacedDigit()).foregroundStyle(.secondary)
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Calendar.current.isDateInToday(day.date) ? accent : accent.opacity(0.35))
                            .frame(height: max(3, 64 * CGFloat(day.minutes) / CGFloat(peak)))
                        Text(day.date.formatted(.dateTime.weekday(.narrow))).font(.caption2).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .bottom)
                }
            }
            .frame(height: 100, alignment: .bottom)
        }
    }

    private var historyCard: some View {
        card("Recent sessions", trailing: {
            if !model.pomodoroHistory.isEmpty {
                Button("Clear") { confirmClear = true }.buttonStyle(.plain).font(.caption).foregroundStyle(.secondary)
            }
        }) {
            if model.pomodoroHistory.isEmpty {
                Text("Finish a focus session and it will show up here.")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(model.pomodoroHistory.suffix(5).reversed())) { session in
                        HStack {
                            Text(session.task.isEmpty ? "Untitled focus" : session.task)
                                .foregroundStyle(session.task.isEmpty ? .secondary : .primary).lineLimit(1)
                            Spacer()
                            Text("\(session.minutes) min").monospacedDigit().foregroundStyle(.secondary)
                        }
                        .font(.callout).padding(.vertical, 6)
                        if session.id != model.pomodoroHistory.suffix(5).first?.id { Divider().opacity(0.4) }
                    }
                }
            }
        }
    }

    private var settingsCard: some View {
        card("Settings", trailing: {
            Button { withAnimation(.easeInOut(duration: 0.2)) { showSettings.toggle() } } label: {
                Image(systemName: showSettings ? "chevron.up" : "chevron.down")
            }
            .buttonStyle(.plain).foregroundStyle(.secondary).accessibilityLabel(showSettings ? "Hide settings" : "Show settings")
        }) {
            if showSettings {
                VStack(alignment: .leading, spacing: 10) {
                    Stepper("Focus: \(model.workMinutes) min", value: $model.workMinutes, in: 1...180)
                    Stepper("Short break: \(model.shortBreakMinutes) min", value: $model.shortBreakMinutes, in: 1...60)
                    Stepper("Long break: \(model.longBreakMinutes) min", value: $model.longBreakMinutes, in: 1...120)
                    Stepper("Long break every \(model.longBreakInterval) sessions", value: $model.longBreakInterval, in: 1...12)
                    Stepper("Daily goal: \(model.pomodoroDailyGoal) sessions", value: $model.pomodoroDailyGoal, in: 1...24)
                    Toggle("Auto-start the next phase", isOn: $model.autoStartPomodoro)
                    Toggle("Confetti when a phase ends", isOn: $model.pomodoroConfetti)
                    Toggle("Play a chime when a phase ends", isOn: $model.pomodoroChime)
                    Button { model.celebratePhaseEnd(.work) } label: { Label("Preview celebration", systemImage: "party.popper") }
                    Divider().opacity(0.4)
                    Toggle("Change soundscape per phase", isOn: $model.changesSoundscapeWithPomodoro)
                    if model.changesSoundscapeWithPomodoro {
                        ForEach(PomodoroPhase.allCases, id: \.self) { phase in
                            Picker(phase.title, selection: Binding(
                                get: { model.pomodoroSoundID(for: phase) },
                                set: { model.setPomodoroSoundID($0, for: phase) }
                            )) {
                                Text("Suggested (\(phase.presets.first?.name ?? "auto"))").tag("")
                                Section("Suggestions") {
                                    ForEach(phase.presets) { Label($0.name, systemImage: $0.icon).tag("preset:\($0.id)") }
                                }
                                if !model.mixes.isEmpty {
                                    Section("My mixes") {
                                        ForEach(model.mixes) { Label($0.name, systemImage: "square.stack").tag("mix:\($0.id.uuidString)") }
                                    }
                                }
                                Section("Single sound") {
                                    ForEach(model.availableLibrary) { sound in
                                        Label(sound.name, systemImage: sound.icon).tag(sound.id)
                                    }
                                }
                            }
                        }
                        HStack {
                            Text("Base volume")
                            Slider(value: $model.pomodoroSoundVolume, in: 0...1)
                            Text("\(Int(model.pomodoroSoundVolume * 100))%")
                                .monospacedDigit().foregroundStyle(.secondary).frame(width: 36, alignment: .trailing)
                        }
                        Button("Apply \(model.pomodoroPhase.title) sound now") { model.applyPomodoroSoundscape() }
                    }
                }
                .font(.callout)
            } else {
                Text("\(model.workMinutes)/\(model.shortBreakMinutes)/\(model.longBreakMinutes) min · long break every \(model.longBreakInterval)")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    private func minutesText(_ minutes: Int) -> String {
        minutes >= 60 ? "\(minutes / 60)h \(minutes % 60)m" : "\(minutes)m"
    }
}
