import SwiftUI

/// The Routines page: things Brisa does for you at set times.
struct RoutinesView: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var themeStore = BrisaThemeStore.shared
    @State private var editing: Routine?
    @State private var editingIsNew = false

    private var calendar: Calendar { .current }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Routines").font(.system(size: 30, weight: .semibold, design: .rounded))
                        Text("Let Brisa start your focus, sounds and reminders at the right time.")
                            .font(.system(size: 13)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button { edit(Routine(name: "", hour: 9, minute: 0, weekdays: Routine.weekdaysOnly, actions: []), isNew: true) } label: {
                        Label("New routine", systemImage: "plus").font(.system(size: 13, weight: .semibold))
                            .padding(.horizontal, 16).padding(.vertical, 9)
                            .background(accent, in: Capsule()).foregroundStyle(onAccent)
                    }.buttonStyle(.plain)
                }

                if !model.routines.isEmpty {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 380), spacing: 16)], spacing: 16) {
                        ForEach(model.routines) { routine in card(routine) }
                    }
                }

                templates

                Text("Routines run while Brisa is open, including in the menu bar. Turn on “Open Brisa at login” in Settings so they are always ready. If your Mac was asleep at the time, a routine still runs when it wakes, as long as it's within 15 minutes. A sleeping Mac can't play sounds, so wake-up routines need the Mac to stay awake (for example, plugged in with only the display off).")
                    .font(.caption).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 34).padding(.bottom, 24).padding(.top, 4)
        }
        .sheet(item: $editing) { routine in
            RoutineEditor(model: model, routine: routine, isNew: editingIsNew)
        }
    }

    private func edit(_ routine: Routine, isNew: Bool) {
        editingIsNew = isNew
        editing = routine
    }

    // MARK: Templates

    private var templates: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(model.routines.isEmpty ? "Start from a template" : "Templates")
                .font(.caption.weight(.bold)).tracking(1.2).textCase(.uppercase).foregroundStyle(.secondary)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 250), spacing: 12)], spacing: 12) {
                ForEach(RoutineTemplates.all) { template in
                    Button { edit(template.make(), isNew: true) } label: {
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: template.symbol).font(.system(size: 18)).frame(width: 28).foregroundStyle(accent)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(template.title).font(.system(size: 14, weight: .medium))
                                Text(template.detail).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.leading)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(14).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        .background(surface.opacity(0.04), in: RoundedRectangle(cornerRadius: 16))
                    }
                    .buttonStyle(.plain).accessibilityLabel("Use the \(template.title) template")
                }
            }
        }
    }

    // MARK: Card

    private func card(_ routine: Routine) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(routine.name).font(.system(size: 16, weight: .semibold)).lineLimit(1)
                    Text(routine.timeText).font(.system(size: 34, weight: .light, design: .rounded).monospacedDigit())
                        .foregroundStyle(routine.isEnabled ? .primary : .secondary)
                }
                Spacer()
                Toggle("", isOn: Binding(get: { routine.isEnabled }, set: { value in
                    var copy = routine; copy.isEnabled = value; model.updateRoutine(copy)
                })).labelsHidden().toggleStyle(.switch).accessibilityLabel("\(routine.name) enabled")
            }

            HStack(spacing: 5) {
                ForEach(0..<7, id: \.self) { index in
                    let weekday = (calendar.firstWeekday - 1 + index) % 7 + 1
                    let on = routine.weekdays.contains(weekday)
                    Text(calendar.veryShortWeekdaySymbols[weekday - 1])
                        .font(.system(size: 11, weight: .semibold)).frame(width: 24, height: 24)
                        .background(on ? accent.opacity(0.9) : surface.opacity(0.07), in: Circle())
                        .foregroundStyle(on ? onAccent : .secondary)
                }
                Text(RoutineSchedule.daysText(routine.weekdays)).font(.caption).foregroundStyle(.secondary).padding(.leading, 6)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(RoutineSchedule.daysText(routine.weekdays))

            VStack(alignment: .leading, spacing: 7) {
                ForEach(routine.actions) { action in
                    Label(model.routineSummary(action), systemImage: action.kind.symbol)
                        .font(.system(size: 13)).lineLimit(1).labelStyle(.titleAndIcon)
                }
            }.opacity(routine.isEnabled ? 1 : 0.5)

            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(nextText(routine)).font(.caption.weight(.medium)).foregroundStyle(routine.isEnabled ? accent : .secondary)
                    if let last = routine.lastRun {
                        Text("Last ran \(last.formatted(.relative(presentation: .named)))").font(.caption2).foregroundStyle(.tertiary)
                    }
                }
                Spacer()
                Button { model.runRoutine(routine) } label: { Image(systemName: "play.fill").font(.system(size: 12)).frame(width: 30, height: 30).background(surface.opacity(0.08), in: Circle()) }
                    .buttonStyle(.plain).help("Run now").accessibilityLabel("Run \(routine.name) now")
                Button { edit(routine, isNew: false) } label: { Image(systemName: "pencil").font(.system(size: 12)).frame(width: 30, height: 30).background(surface.opacity(0.08), in: Circle()) }
                    .buttonStyle(.plain).help("Edit").accessibilityLabel("Edit \(routine.name)")
                Button { withAnimation { model.removeRoutine(routine.id) } } label: { Image(systemName: "trash").font(.system(size: 12)).frame(width: 30, height: 30).background(surface.opacity(0.08), in: Circle()) }
                    .buttonStyle(.plain).help("Delete").accessibilityLabel("Delete \(routine.name)")
            }
        }
        .padding(18).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(surface.opacity(0.05), in: RoundedRectangle(cornerRadius: 20))
    }

    private func nextText(_ routine: Routine) -> String {
        guard routine.isEnabled else { return "Paused" }
        guard let next = RoutineSchedule.nextRun(of: routine, after: Date()) else { return "No days selected" }
        let day = calendar.isDateInToday(next) ? "Today" : calendar.isDateInTomorrow(next) ? "Tomorrow" : next.formatted(.dateTime.weekday(.wide))
        return "Next: \(day) at \(next.formatted(date: .omitted, time: .shortened))"
    }
}

/// Create or edit one routine.
struct RoutineEditor: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var themeStore = BrisaThemeStore.shared
    @Environment(\.dismiss) private var dismiss
    @State var routine: Routine
    let isNew: Bool

    private var calendar: Calendar { .current }
    private var canSave: Bool {
        !routine.name.trimmingCharacters(in: .whitespaces).isEmpty && !routine.actions.isEmpty && !routine.weekdays.isEmpty
    }

    private var timeBinding: Binding<Date> {
        Binding(
            get: { calendar.date(bySettingHour: routine.hour, minute: routine.minute, second: 0, of: Date()) ?? Date() },
            set: { routine.hour = calendar.component(.hour, from: $0); routine.minute = calendar.component(.minute, from: $0) })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(isNew ? "New routine" : "Edit routine").font(.title2.weight(.semibold)).padding(.bottom, 16)
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    TextField("Name, e.g. Morning focus", text: $routine.name).textFieldStyle(.roundedBorder)

                    section("When") {
                        HStack {
                            DatePicker("Time", selection: timeBinding, displayedComponents: .hourAndMinute).labelsHidden()
                            Spacer()
                            Menu("Quick pick") {
                                Button("Every day") { routine.weekdays = Routine.everyDay }
                                Button("Weekdays") { routine.weekdays = Routine.weekdaysOnly }
                                Button("Weekends") { routine.weekdays = Routine.weekend }
                            }.menuStyle(.borderlessButton).fixedSize()
                        }
                        HStack(spacing: 6) {
                            ForEach(0..<7, id: \.self) { index in
                                let weekday = (calendar.firstWeekday - 1 + index) % 7 + 1
                                let on = routine.weekdays.contains(weekday)
                                Button {
                                    if on { routine.weekdays.remove(weekday) } else { routine.weekdays.insert(weekday) }
                                } label: {
                                    Text(calendar.shortWeekdaySymbols[weekday - 1]).font(.system(size: 12, weight: .medium))
                                        .frame(maxWidth: .infinity).padding(.vertical, 8)
                                        .background(on ? accent : surface.opacity(0.08), in: RoundedRectangle(cornerRadius: 9))
                                        .foregroundStyle(on ? onAccent : .primary)
                                }
                                .buttonStyle(.plain).accessibilityLabel(calendar.weekdaySymbols[weekday - 1]).accessibilityAddTraits(on ? .isSelected : [])
                            }
                        }
                    }

                    section("Then, in order") {
                        if routine.actions.isEmpty {
                            Text("Add at least one action.").font(.callout).foregroundStyle(.secondary)
                        }
                        ForEach($routine.actions) { $action in actionRow($action) }
                        Menu {
                            ForEach(RoutineAction.Kind.allCases, id: \.self) { kind in
                                Button { routine.actions.append(newAction(kind)) } label: { Label(kind.title, systemImage: kind.symbol) }
                            }
                        } label: { Label("Add an action", systemImage: "plus.circle.fill") }
                            .menuStyle(.borderlessButton).fixedSize()
                    }

                    Toggle("Notify me when it starts", isOn: $routine.announce)
                }
                .padding(.trailing, 6)
            }
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Test now") { model.runRoutine(routine) }.disabled(routine.actions.isEmpty)
                Button("Save") {
                    routine.name = routine.name.trimmingCharacters(in: .whitespaces)
                    if isNew { model.addRoutine(routine) } else { model.updateRoutine(routine) }
                    dismiss()
                }.keyboardShortcut(.defaultAction).disabled(!canSave)
            }.padding(.top, 16)
        }
        .padding(28).frame(width: 540, height: 640)
        .preferredColorScheme(themeStore.current.scheme).tint(accent)
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.caption.weight(.bold)).tracking(1.2).textCase(.uppercase).foregroundStyle(.secondary)
            content()
        }
    }

    private func newAction(_ kind: RoutineAction.Kind) -> RoutineAction {
        switch kind {
        case .playSound: return RoutineAction(kind: kind, choice: "scene:deepFocus")
        case .startBreak: return RoutineAction(kind: kind, choice: "short")
        case .playVideo: return RoutineAction(kind: kind, choice: model.youtubeVideos.first?.id ?? "")
        case .sleepTimer: return RoutineAction(kind: kind, number: 30)
        case .setVolume: return RoutineAction(kind: kind, number: 40)
        case .startMode: return RoutineAction(kind: kind, choice: model.modes.first?.id.uuidString ?? "")
        default: return RoutineAction(kind: kind)
        }
    }

    // MARK: One action

    private func actionRow(_ action: Binding<RoutineAction>) -> some View {
        let value = action.wrappedValue
        return HStack(alignment: .center, spacing: 10) {
            Image(systemName: value.kind.symbol).frame(width: 22).foregroundStyle(accent)
            VStack(alignment: .leading, spacing: 6) {
                Text(value.kind.title).font(.system(size: 13, weight: .medium))
                switch value.kind {
                case .playSound: soundPicker(action.choice)
                case .startFocus: taskPicker(action.choice)
                case .startBreak:
                    Picker("", selection: action.choice) { Text("Short break").tag("short"); Text("Long break").tag("long") }
                        .labelsHidden().pickerStyle(.segmented).frame(maxWidth: 240)
                case .playVideo: videoPicker(action.choice)
                case .sleepTimer:
                    Stepper("\(value.number) minutes", value: action.number, in: 5...480, step: 5).font(.callout)
                case .setVolume:
                    HStack { Slider(value: Binding(get: { Double(action.wrappedValue.number) }, set: { action.wrappedValue.number = Int($0) }), in: 5...100, step: 5)
                        Text("\(value.number)%").font(.callout.monospacedDigit()).frame(width: 40, alignment: .trailing) }
                case .notify:
                    TextField("Reminder text", text: action.text).textFieldStyle(.roundedBorder)
                case .startMode: modePicker(action.choice)
                case .stopSounds, .stopFocus, .endMode: EmptyView()
                }
            }
            Spacer(minLength: 0)
            VStack(spacing: 2) {
                Button { move(value.id, by: -1) } label: { Image(systemName: "chevron.up") }.buttonStyle(.plain).accessibilityLabel("Move up")
                Button { move(value.id, by: 1) } label: { Image(systemName: "chevron.down") }.buttonStyle(.plain).accessibilityLabel("Move down")
            }.font(.caption).foregroundStyle(.secondary)
            Button { routine.actions.removeAll { $0.id == value.id } } label: { Image(systemName: "xmark.circle.fill") }
                .buttonStyle(.plain).foregroundStyle(.tertiary).accessibilityLabel("Remove action")
        }
        .padding(12).background(surface.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
    }

    private func move(_ id: UUID, by offset: Int) {
        guard let index = routine.actions.firstIndex(where: { $0.id == id }), routine.actions.indices.contains(index + offset) else { return }
        routine.actions.swapAt(index, index + offset)
    }

    private func soundPicker(_ choice: Binding<String>) -> some View {
        SoundChoicePicker(model: model, choice: choice)
    }

    @ViewBuilder
    private func modePicker(_ choice: Binding<String>) -> some View {
        if model.modes.isEmpty {
            Text("Create a mode in the Modes tab first.").font(.caption).foregroundStyle(.secondary)
        } else {
            Picker("", selection: choice) { ForEach(model.modes) { Label($0.name, systemImage: $0.symbol).tag($0.id.uuidString) } }.labelsHidden()
        }
    }

    private func taskPicker(_ choice: Binding<String>) -> some View {
        Picker("", selection: choice) {
            Text("No specific task").tag("")
            ForEach(model.pomodoroTasks.filter { !$0.isDone }) { Text($0.title).tag($0.id.uuidString) }
        }.labelsHidden()
    }

    @ViewBuilder
    private func videoPicker(_ choice: Binding<String>) -> some View {
        if model.youtubeVideos.isEmpty {
            Text("Add a YouTube link in Import audio first.").font(.caption).foregroundStyle(.secondary)
        } else {
            Picker("", selection: choice) { ForEach(model.youtubeVideos) { Text($0.name).tag($0.id) } }.labelsHidden()
        }
    }
}

/// Scenes, suggestions, saved mixes and single sounds, in the choice format Routines and Modes store.
struct SoundChoicePicker: View {
    @ObservedObject var model: AppModel
    @Binding var choice: String
    var allowsNone = false

    var body: some View {
        Picker("", selection: $choice) {
            if allowsNone { Text("No sound").tag("") }
            Section("Scenes") { ForEach(RoutineSounds.scenes) { Text($0.name).tag("scene:\($0.id)") } }
            ForEach(PomodoroPhase.allCases, id: \.self) { phase in
                Section("\(phase.title) suggestions") {
                    ForEach(phase.presets) { Text($0.name).tag("preset:\(phase.rawValue).\($0.id)") }
                }
            }
            if !model.mixes.isEmpty {
                Section("My mixes") { ForEach(model.mixes) { Text($0.name).tag("mix:\($0.id.uuidString)") } }
            }
            Section("Single sound") { ForEach(model.availableLibrary) { Text($0.name).tag($0.id) } }
        }.labelsHidden()
    }
}
