import Foundation
import UserNotifications

/// One step of a routine. The meaning of `choice`, `number` and `text` depends on `kind`.
struct RoutineAction: Codable, Identifiable, Equatable {
    enum Kind: String, Codable, CaseIterable {
        case playSound, startFocus, startBreak, playVideo, sleepTimer, setVolume, notify, stopSounds, stopFocus, startMode, endMode

        var title: String {
            switch self {
            case .playSound: return "Play sounds"
            case .startFocus: return "Start a focus session"
            case .startBreak: return "Start a break"
            case .playVideo: return "Play a video"
            case .sleepTimer: return "Stop sounds after…"
            case .setVolume: return "Set the volume"
            case .notify: return "Show a reminder"
            case .stopSounds: return "Stop the sounds"
            case .stopFocus: return "Pause the focus timer"
            case .startMode: return "Start a mode"
            case .endMode: return "End the current mode"
            }
        }

        var symbol: String {
            switch self {
            case .playSound: return "waveform"
            case .startFocus: return "brain.head.profile"
            case .startBreak: return "cup.and.saucer.fill"
            case .playVideo: return "play.rectangle.fill"
            case .sleepTimer: return "moon.zzz"
            case .setVolume: return "speaker.wave.2"
            case .notify: return "bell"
            case .stopSounds: return "stop.circle"
            case .stopFocus: return "pause.circle"
            case .startMode: return "rectangle.3.group"
            case .endMode: return "rectangle.3.group.bubble"
            }
        }
    }

    var id = UUID()
    var kind: Kind
    /// playSound: a sound source (see `RoutineSounds`); startFocus: a task ID or empty; startBreak: "short" or "long";
    /// playVideo: a video's library ID; startMode: a mode's ID.
    var choice: String = ""
    /// sleepTimer: minutes; setVolume: percent.
    var number: Int = 0
    /// notify: the reminder text.
    var text: String = ""
}

struct Routine: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var isEnabled = true
    var hour: Int
    var minute: Int
    /// Calendar weekdays: 1 = Sunday … 7 = Saturday.
    var weekdays: Set<Int>
    var actions: [RoutineAction]
    /// Show a notification when the routine starts, so a sound never begins by surprise.
    var announce = true
    var lastRun: Date?

    var timeText: String { String(format: "%02d:%02d", hour, minute) }

    static let everyDay: Set<Int> = Set(1...7)
    static let weekdaysOnly: Set<Int> = [2, 3, 4, 5, 6]
    static let weekend: Set<Int> = [1, 7]
}

/// Pure scheduling maths, kept free of app state so it can be tested.
enum RoutineSchedule {
    /// A routine that was due while the Mac was asleep or Brisa was closed still runs if it's at most this old.
    static let catchUpWindow: TimeInterval = 15 * 60

    static func occurrence(of routine: Routine, on day: Date, calendar: Calendar = .current) -> Date? {
        guard routine.weekdays.contains(calendar.component(.weekday, from: day)) else { return nil }
        return calendar.date(bySettingHour: routine.hour, minute: routine.minute, second: 0, of: day)
    }

    /// Times the routine fires in (start, end].
    static func occurrences(of routine: Routine, after start: Date, through end: Date, calendar: Calendar = .current) -> [Date] {
        guard start < end else { return [] }
        var result: [Date] = []
        var day = calendar.startOfDay(for: start)
        let last = calendar.startOfDay(for: end)
        while day <= last {
            if let time = occurrence(of: routine, on: day, calendar: calendar), time > start, time <= end { result.append(time) }
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }
        return result
    }

    static func nextRun(of routine: Routine, after date: Date, calendar: Calendar = .current) -> Date? {
        guard routine.isEnabled, !routine.weekdays.isEmpty else { return nil }
        let start = calendar.startOfDay(for: date)
        for offset in 0...8 {
            guard let day = calendar.date(byAdding: .day, value: offset, to: start),
                  let time = occurrence(of: routine, on: day, calendar: calendar), time > date else { continue }
            return time
        }
        return nil
    }

    /// Enabled routines whose time fell between the last check and now, never older than the catch-up window.
    static func due(_ routines: [Routine], lastCheck: Date, now: Date, calendar: Calendar = .current) -> [Routine] {
        let start = max(lastCheck, now.addingTimeInterval(-catchUpWindow))
        return routines.filter { $0.isEnabled && !occurrences(of: $0, after: start, through: now, calendar: calendar).isEmpty }
    }

    static func daysText(_ weekdays: Set<Int>, calendar: Calendar = .current) -> String {
        if weekdays == Routine.everyDay { return "Every day" }
        if weekdays == Routine.weekdaysOnly { return "Weekdays" }
        if weekdays == Routine.weekend { return "Weekends" }
        if weekdays.isEmpty { return "Never" }
        let names = calendar.shortWeekdaySymbols
        return weekdays.sorted().map { names[$0 - 1] }.joined(separator: ", ")
    }
}

/// Built-in scenes and the way a sound choice is turned into levels.
enum RoutineSounds {
    struct Scene: Identifiable { let id: String; let name: String; let icon: String; let levels: [String: Double] }

    static let scenes: [Scene] = [
        Scene(id: "deepFocus", name: "Deep focus", icon: "scope", levels: ["brown": 0.05, "rain": 0.05]),
        Scene(id: "quietBreak", name: "Quiet break", icon: "leaf", levels: ["ocean": 0.05, "wind": 0.05]),
        Scene(id: "goodNight", name: "Good night", icon: "moon", levels: ["pink": 0.05, "night": 0.05])
    ]

    @MainActor static func title(for choice: String, in model: AppModel) -> String {
        if choice.hasPrefix("mix:") { return model.mixes.first { "mix:\($0.id.uuidString)" == choice }?.name ?? "A deleted mix" }
        if choice.hasPrefix("scene:") { return scenes.first { "scene:\($0.id)" == choice }?.name ?? "A scene" }
        if choice.hasPrefix("preset:") {
            let parts = choice.dropFirst(7).split(separator: ".").map(String.init)
            if parts.count == 2, let phase = PomodoroPhase(rawValue: parts[0]), let preset = phase.presets.first(where: { $0.id == parts[1] }) { return preset.name }
            return "A suggestion"
        }
        return model.availableLibrary.first { $0.id == choice }?.name ?? "A sound"
    }
}

extension AppModel {
    /// The levels a sound choice stands for, or nil if the mix, scene or sound no longer exists.
    func routineLevels(for choice: String) -> [String: Double]? {
        if choice.hasPrefix("mix:") { return mixes.first { "mix:\($0.id.uuidString)" == choice }?.levels }
        if choice.hasPrefix("scene:") { return RoutineSounds.scenes.first { "scene:\($0.id)" == choice }?.levels }
        if choice.hasPrefix("preset:") {
            let parts = choice.dropFirst(7).split(separator: ".").map(String.init)
            guard parts.count == 2, let phase = PomodoroPhase(rawValue: parts[0]),
                  let preset = phase.presets.first(where: { $0.id == parts[1] }) else { return nil }
            let levels = pomodoroLevels(for: preset)
            return levels.isEmpty ? nil : levels
        }
        return availableLibrary.contains { $0.id == choice } ? [choice: 0.05] : nil
    }

    /// Plays a sound choice; saved mixes keep their stereo positions.
    func playSoundChoice(_ choice: String) {
        if let mix = mixes.first(where: { "mix:\($0.id.uuidString)" == choice }) { applyMix(mix) }
        else if let levels = routineLevels(for: choice) { applyMix(levels) }
    }

    func routineSummary(_ action: RoutineAction) -> String {
        switch action.kind {
        case .playSound: return "Play \(RoutineSounds.title(for: action.choice, in: self))"
        case .startFocus:
            if let id = UUID(uuidString: action.choice), let task = pomodoroTasks.first(where: { $0.id == id }) { return "Start focus on “\(task.title)”" }
            return "Start a focus session"
        case .startBreak: return action.choice == "long" ? "Start a long break" : "Start a short break"
        case .playVideo: return "Play “\(importedSounds.first { $0.id == action.choice }?.name ?? "a removed video")”"
        case .sleepTimer: return "Stop sounds after \(action.number) min"
        case .setVolume: return "Set the volume to \(action.number)%"
        case .notify: return action.text.isEmpty ? "Show a reminder" : "Remind: \(action.text)"
        case .stopSounds: return "Stop the sounds"
        case .stopFocus: return "Pause the focus timer"
        case .startMode: return "Start \(modes.first { $0.id.uuidString == action.choice }?.name ?? "a deleted mode")"
        case .endMode: return "End the current mode"
        }
    }

    // MARK: Scheduling

    /// Called every second from the app timer; cheap because it only compares dates.
    func checkRoutines(now: Date = Date()) {
        let due = RoutineSchedule.due(routines, lastCheck: lastRoutineCheck, now: now)
        lastRoutineCheck = now
        if now.timeIntervalSince(lastRoutineCheckSaved) > 30 || !due.isEmpty {
            UserDefaults.standard.set(now.timeIntervalSince1970, forKey: "routines.lastCheck")
            lastRoutineCheckSaved = now
        }
        for routine in due { runRoutine(routine) }
    }

    func runRoutine(_ routine: Routine) {
        isAutomaticChange = true   // routine-driven changes don't count towards "Most used"
        defer { isAutomaticChange = false }
        if routine.announce { announceRoutine(routine) }
        for action in routine.actions { perform(action, in: routine) }
        if let index = routines.firstIndex(where: { $0.id == routine.id }) { routines[index].lastRun = Date() }
    }

    private func perform(_ action: RoutineAction, in routine: Routine) {
        switch action.kind {
        case .playSound:
            playSoundChoice(action.choice)
        case .startFocus:
            if let id = UUID(uuidString: action.choice), pomodoroTasks.contains(where: { $0.id == id && !$0.isDone }) { selectPomodoroTask(id) }
            resetPomodoro()
            startPomodoro()
        case .startBreak:
            pausePomodoro()
            selectPomodoroPhase(action.choice == "long" ? .longBreak : .shortBreak)
            startPomodoro()
        case .playVideo:
            if let video = importedSounds.first(where: { $0.id == action.choice }), !YouTubeVideoPlayer.shared.isCurrent(video) {
                YouTubeVideoPlayer.shared.toggle(video)
            }
        case .sleepTimer:
            remainingSeconds = max(0, action.number) * 60
        case .setVolume:
            masterVolume = min(max(Double(action.number) / 100, 0), 1)
            synchronizeAudio()
        case .notify:
            sendRoutineNotification(title: routine.name, body: action.text)
        case .stopSounds:
            isPlaying = false
            synchronizeAudio()
        case .stopFocus:
            pausePomodoro()
        case .startMode:
            if let mode = modes.first(where: { $0.id.uuidString == action.choice }) { startMode(mode) }
        case .endMode:
            endMode()
        }
    }

    private func announceRoutine(_ routine: Routine) {
        // A reminder action already shows its own message, so only announce routines that do more than remind.
        guard routine.actions.contains(where: { $0.kind != .notify }) else { return }
        let steps = routine.actions.filter { $0.kind != .notify }.map { routineSummary($0) }.joined(separator: " · ")
        sendRoutineNotification(title: "\(routine.name) started", body: steps)
    }

    private func sendRoutineNotification(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    func persistRoutines() {
        guard let data = try? JSONEncoder().encode(routines) else { return }
        UserDefaults.standard.set(data, forKey: "routines")
    }

    func loadRoutines() {
        if let data = UserDefaults.standard.data(forKey: "routines"), let saved = try? JSONDecoder().decode([Routine].self, from: data) { routines = saved }
        let stored = UserDefaults.standard.double(forKey: "routines.lastCheck")
        // First launch: start counting from now so nothing old fires.
        lastRoutineCheck = stored > 0 ? Date(timeIntervalSince1970: stored) : Date()
        lastRoutineCheckSaved = lastRoutineCheck
    }

    // MARK: Editing

    func addRoutine(_ routine: Routine) { routines.append(routine) }

    func updateRoutine(_ routine: Routine) {
        guard let index = routines.firstIndex(where: { $0.id == routine.id }) else { return }
        routines[index] = routine
    }

    func removeRoutine(_ id: UUID) { routines.removeAll { $0.id == id } }
}

/// Ready-made routines to start from.
enum RoutineTemplates {
    struct Template: Identifiable {
        let id: String, title: String, detail: String, symbol: String
        let make: () -> Routine
    }

    static let all: [Template] = [
        Template(id: "morningFocus", title: "Morning focus", detail: "9:00 on weekdays: deep-focus sound and a focus session.", symbol: "sunrise") {
            Routine(name: "Morning focus", hour: 9, minute: 0, weekdays: Routine.weekdaysOnly, actions: [
                RoutineAction(kind: .playSound, choice: "preset:work.deep"), RoutineAction(kind: .startFocus)])
        },
        Template(id: "lunchBreak", title: "Lunch break", detail: "12:30 on weekdays: stops everything and reminds you to step away.", symbol: "fork.knife") {
            Routine(name: "Lunch break", hour: 12, minute: 30, weekdays: Routine.weekdaysOnly, actions: [
                RoutineAction(kind: .stopFocus), RoutineAction(kind: .stopSounds),
                RoutineAction(kind: .notify, text: "Lunch time. Step away from the screen.")])
        },
        Template(id: "stretch", title: "Stretch reminder", detail: "15:30 on weekdays: a nudge to stand up.", symbol: "figure.walk") {
            Routine(name: "Stretch reminder", hour: 15, minute: 30, weekdays: Routine.weekdaysOnly, actions: [
                RoutineAction(kind: .notify, text: "Stand up and stretch for two minutes.")])
        },
        Template(id: "windDown", title: "Wind down", detail: "22:00 every day: quiet volume, night sounds, off after 30 minutes.", symbol: "moon.stars") {
            Routine(name: "Wind down", hour: 22, minute: 0, weekdays: Routine.everyDay, actions: [
                RoutineAction(kind: .setVolume, number: 40), RoutineAction(kind: .playSound, choice: "scene:goodNight"),
                RoutineAction(kind: .sleepTimer, number: 30)])
        },
        Template(id: "gentleWake", title: "Gentle wake-up", detail: "7:00 every day: forest birds at low volume. The Mac must be awake at that time.", symbol: "bird") {
            Routine(name: "Gentle wake-up", hour: 7, minute: 0, weekdays: Routine.everyDay, actions: [
                RoutineAction(kind: .setVolume, number: 25), RoutineAction(kind: .playSound, choice: "realForest"),
                RoutineAction(kind: .sleepTimer, number: 45)])
        }
    ]
}
