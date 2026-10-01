import Foundation

/// Something to do during a break: drink water, stretch, play a game… The list is the user's to edit.
struct BreakActivity: Codable, Identifiable, Equatable {
    /// Which breaks the activity is offered in.
    enum Fit: String, Codable, CaseIterable, Identifiable {
        case any, short, long
        var id: String { rawValue }

        var title: String {
            switch self {
            case .any: return "Any break"
            case .short: return "Short breaks"
            case .long: return "Long breaks"
            }
        }
    }

    var id = UUID()
    var title: String
    var symbol: String
    /// A short hint shown under the title, e.g. "A full glass".
    var note = ""
    var fit = Fit.any
    /// Break length this activity needs, in minutes. Nil leaves the break as it is.
    var minutes: Int?
    /// Opened when the activity is picked: a web or app link, or the path of an app.
    var opens = ""
    var isEnabled = true

    func fits(_ phase: PomodoroPhase) -> Bool {
        switch (fit, phase) {
        case (_, .work): return false
        case (.any, _), (.short, .shortBreak), (.long, .longBreak): return true
        default: return false
        }
    }
}

extension BreakActivity {
    enum CodingKeys: String, CodingKey { case id, title, symbol, note, fit, minutes, opens, isEnabled }

    /// Everything but the title is optional, so lists saved by other versions still load.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        title = try c.decode(String.self, forKey: .title)
        symbol = try c.decodeIfPresent(String.self, forKey: .symbol) ?? "sparkles"
        note = try c.decodeIfPresent(String.self, forKey: .note) ?? ""
        fit = (try? c.decodeIfPresent(Fit.self, forKey: .fit)) ?? .any
        minutes = try c.decodeIfPresent(Int.self, forKey: .minutes)
        opens = try c.decodeIfPresent(String.self, forKey: .opens) ?? ""
        isEnabled = try c.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
    }
}

/// One break, and what was done in it.
struct BreakLogEntry: Codable, Equatable {
    var date: Date
    /// Nil for something typed in on the spot.
    var activityID: UUID?
    var title: String
}

/// Pure rules for break activities, kept free of app state so they can be tested.
enum BreakActivities {
    static let logLimit = 300

    static var defaults: [BreakActivity] {
        [
            BreakActivity(title: "Drink water", symbol: "drop.fill", note: "A full glass"),
            BreakActivity(title: "Stretch", symbol: "figure.flexibility", note: "Neck, shoulders and back"),
            BreakActivity(title: "Rest your eyes", symbol: "eye", note: "Look far away for 20 seconds", fit: .short),
            BreakActivity(title: "Breathe", symbol: "wind", note: "Four slow, deep breaths", fit: .short),
            BreakActivity(title: "Take a walk", symbol: "figure.walk", note: "Some light and movement", fit: .long),
            BreakActivity(title: "Play a game", symbol: "gamecontroller.fill", note: "Something quick and fun", fit: .long),
            BreakActivity(title: "Have a snack", symbol: "carrot.fill", fit: .long),
            BreakActivity(title: "Tidy up", symbol: "sparkles", note: "Clear your desk")
        ]
    }

    /// Icons offered when creating or editing an activity.
    static let symbols = [
        "drop.fill", "cup.and.saucer.fill", "carrot.fill", "fork.knife", "figure.flexibility", "figure.walk",
        "figure.run", "figure.mind.and.body", "dumbbell.fill", "eye", "wind", "leaf.fill",
        "sun.max.fill", "moon.zzz.fill", "bed.double.fill", "gamecontroller.fill", "puzzlepiece.fill", "book.fill",
        "music.note", "guitars.fill", "paintbrush.fill", "phone.fill", "message.fill", "pawprint.fill",
        "heart.fill", "tree.fill", "sparkles", "hands.clap.fill"
    ]

    /// What to offer for a break: enabled activities that suit it, in the user's order.
    static func available(_ all: [BreakActivity], for phase: PomodoroPhase) -> [BreakActivity] {
        all.filter { $0.isEnabled && $0.fits(phase) }
    }

    /// The activity done least recently (never done comes first, ties keep the user's order), so breaks vary.
    static func suggestion(from candidates: [BreakActivity], log: [BreakLogEntry]) -> BreakActivity? {
        var lastDone: [UUID: Date] = [:]
        for entry in log {
            guard let id = entry.activityID else { continue }
            lastDone[id] = max(lastDone[id] ?? .distantPast, entry.date)
        }
        return candidates.min { (lastDone[$0.id] ?? .distantPast) < (lastDone[$1.id] ?? .distantPast) }
    }

    static func count(of id: UUID, in log: [BreakLogEntry], on day: Date, calendar: Calendar = .current) -> Int {
        log.filter { $0.activityID == id && calendar.isDate($0.date, inSameDayAs: day) }.count
    }

    /// What was done on a day, most frequent first, e.g. [("Drink water", 3), ("Stretch", 1)].
    static func summary(of log: [BreakLogEntry], on day: Date, calendar: Calendar = .current) -> [(title: String, count: Int)] {
        var counts: [String: Int] = [:]
        var order: [String] = []
        for entry in log where calendar.isDate(entry.date, inSameDayAs: day) {
            if counts[entry.title] == nil { order.append(entry.title) }
            counts[entry.title, default: 0] += 1
        }
        return order.map { ($0, counts[$0] ?? 0) }.sorted { $0.1 > $1.1 }
    }

    /// Where an activity's "opens" text points: a web or app link, or an app on disk. Nil for anything else.
    static func target(_ text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.hasPrefix("/") || trimmed.hasPrefix("~") {
            let path = (trimmed as NSString).expandingTildeInPath
            return path.lowercased().hasSuffix(".app") ? URL(fileURLWithPath: path) : nil
        }
        guard !trimmed.contains(" ") else { return nil }
        guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased() else {
            // "lichess.org" without a scheme.
            return trimmed.contains(".") ? URL(string: "https://\(trimmed)") : nil
        }
        // Files and scripts are never opened from here; apps are chosen by path instead.
        guard !["file", "javascript", "data"].contains(scheme) else { return nil }
        return url
    }

    /// A readable name for a target: the app's name or the site's host.
    static func targetName(_ url: URL) -> String {
        url.isFileURL ? url.deletingPathExtension().lastPathComponent : (url.host ?? url.absoluteString)
    }
}

/// The user's break activities, what they picked, and how the break screen behaves.
@MainActor
final class BreakStore: ObservableObject {
    static let shared = BreakStore()

    @Published var activities: [BreakActivity] { didSet { Self.save(activities, "breaks.activities") } }
    @Published private(set) var log: [BreakLogEntry] { didSet { Self.save(log, "breaks.log") } }
    /// What was picked for the current (or last) break.
    @Published private(set) var current: BreakLogEntry?

    @Published var showAfterFocus = (UserDefaults.standard.object(forKey: "breaks.afterFocus") as? Bool) ?? true {
        didSet { UserDefaults.standard.set(showAfterFocus, forKey: "breaks.afterFocus") }
    }
    @Published var showAfterBreak = UserDefaults.standard.bool(forKey: "breaks.afterBreak") {
        didSet { UserDefaults.standard.set(showAfterBreak, forKey: "breaks.afterBreak") }
    }
    @Published var staysOpen = UserDefaults.standard.bool(forKey: "breaks.staysOpen") {
        didSet { UserDefaults.standard.set(staysOpen, forKey: "breaks.staysOpen") }
    }
    @Published var dimOtherDisplays = (UserDefaults.standard.object(forKey: "breaks.dimOthers") as? Bool) ?? true {
        didSet { UserDefaults.standard.set(dimOtherDisplays, forKey: "breaks.dimOthers") }
    }

    private init() {
        activities = Self.load("breaks.activities") ?? BreakActivities.defaults
        log = Self.load("breaks.log") ?? []
    }

    func available(for phase: PomodoroPhase) -> [BreakActivity] { BreakActivities.available(activities, for: phase) }
    func suggestion(for phase: PomodoroPhase) -> BreakActivity? { BreakActivities.suggestion(from: available(for: phase), log: log) }
    func timesToday(_ activity: BreakActivity) -> Int { BreakActivities.count(of: activity.id, in: log, on: Date()) }
    var today: [(title: String, count: Int)] { BreakActivities.summary(of: log, on: Date()) }

    func symbol(for entry: BreakLogEntry) -> String {
        activities.first { $0.id == entry.activityID }?.symbol ?? "cup.and.saucer.fill"
    }

    func record(_ activity: BreakActivity?, customTitle: String) {
        let entry = BreakLogEntry(date: Date(), activityID: activity?.id, title: activity?.title ?? customTitle)
        current = entry
        log.append(entry)
        if log.count > BreakActivities.logLimit { log.removeFirst(log.count - BreakActivities.logLimit) }
    }

    func clearCurrent() { current = nil }
    func clearLog() { log = []; current = nil }

    func upsert(_ activity: BreakActivity) {
        if let index = activities.firstIndex(where: { $0.id == activity.id }) { activities[index] = activity }
        else { activities.append(activity) }
    }

    func remove(_ id: UUID) { activities.removeAll { $0.id == id } }

    func move(_ id: UUID, by offset: Int) {
        guard let from = activities.firstIndex(where: { $0.id == id }), activities.indices.contains(from + offset) else { return }
        activities.swapAt(from, from + offset)
    }

    func setEnabled(_ id: UUID, _ enabled: Bool) {
        guard let index = activities.firstIndex(where: { $0.id == id }) else { return }
        activities[index].isEnabled = enabled
    }

    func restoreDefaults() { activities = BreakActivities.defaults }

    private static func load<T: Decodable>(_ key: String) -> T? {
        UserDefaults.standard.data(forKey: key).flatMap { try? JSONDecoder().decode(T.self, from: $0) }
    }

    private static func save<T: Encodable>(_ value: T, _ key: String) {
        if let data = try? JSONEncoder().encode(value) { UserDefaults.standard.set(data, forKey: key) }
    }
}
