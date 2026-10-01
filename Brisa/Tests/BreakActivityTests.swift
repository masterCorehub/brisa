import Foundation

enum BreakActivityTests {
    private static let day = Date(timeIntervalSince1970: 1_790_000_000)

    static let all: [TestCase] = [
        TestCase(name: "activities fit only the breaks they are for") {
            let any = BreakActivity(title: "Water", symbol: "drop.fill")
            let short = BreakActivity(title: "Eyes", symbol: "eye", fit: .short)
            let long = BreakActivity(title: "Walk", symbol: "figure.walk", fit: .long)
            try expect(any.fits(.shortBreak) && any.fits(.longBreak) && !any.fits(.work))
            try expect(short.fits(.shortBreak) && !short.fits(.longBreak))
            try expect(long.fits(.longBreak) && !long.fits(.shortBreak))
        },
        TestCase(name: "available keeps enabled, fitting activities in order") {
            var off = BreakActivity(title: "Off", symbol: "eye")
            off.isEnabled = false
            let list = [BreakActivity(title: "A", symbol: "eye"), off, BreakActivity(title: "B", symbol: "eye", fit: .long),
                        BreakActivity(title: "C", symbol: "eye", fit: .short)]
            try expectEqual(BreakActivities.available(list, for: .shortBreak).map(\.title), ["A", "C"])
            try expectEqual(BreakActivities.available(list, for: .longBreak).map(\.title), ["A", "B"])
        },
        TestCase(name: "suggestion prefers never done, then least recent") {
            let a = BreakActivity(title: "A", symbol: "eye"), b = BreakActivity(title: "B", symbol: "eye"), c = BreakActivity(title: "C", symbol: "eye")
            try expectEqual(BreakActivities.suggestion(from: [a, b, c], log: [])?.title, "A")
            let log = [BreakLogEntry(date: day, activityID: a.id, title: "A"),
                       BreakLogEntry(date: day.addingTimeInterval(60), activityID: c.id, title: "C")]
            try expectEqual(BreakActivities.suggestion(from: [a, b, c], log: log)?.title, "B")
            let later = log + [BreakLogEntry(date: day.addingTimeInterval(120), activityID: b.id, title: "B")]
            try expectEqual(BreakActivities.suggestion(from: [a, b, c], log: later)?.title, "A")
            try expectNil(BreakActivities.suggestion(from: [], log: later))
        },
        TestCase(name: "counts and summary only cover the given day") {
            let a = BreakActivity(title: "Water", symbol: "drop.fill")
            let log = [BreakLogEntry(date: day, activityID: a.id, title: "Water"),
                       BreakLogEntry(date: day.addingTimeInterval(600), activityID: a.id, title: "Water"),
                       BreakLogEntry(date: day.addingTimeInterval(900), activityID: nil, title: "Call mum"),
                       BreakLogEntry(date: day.addingTimeInterval(-3 * 86_400), activityID: a.id, title: "Water")]
            try expectEqual(BreakActivities.count(of: a.id, in: log, on: day), 2)
            let summary = BreakActivities.summary(of: log, on: day)
            try expectEqual(summary.map(\.title), ["Water", "Call mum"])
            try expectEqual(summary.map(\.count), [2, 1])
        },
        TestCase(name: "targets accept links and apps, nothing else") {
            try expectEqual(BreakActivities.target("https://lichess.org")?.absoluteString, "https://lichess.org")
            try expectEqual(BreakActivities.target("  lichess.org ")?.absoluteString, "https://lichess.org")
            try expectEqual(BreakActivities.target("steam://open/games")?.scheme, "steam")
            try expectEqual(BreakActivities.target("/Applications/Chess.app")?.path, "/Applications/Chess.app")
            try expect(BreakActivities.target("/Applications/Chess.app")?.isFileURL == true)
            try expectNil(BreakActivities.target("/etc/passwd"))
            try expectNil(BreakActivities.target("file:///Applications/Chess.app"))
            try expectNil(BreakActivities.target("javascript:alert(1)"))
            try expectNil(BreakActivities.target("play a game"))
            try expectNil(BreakActivities.target(""))
            try expectEqual(BreakActivities.targetName(URL(fileURLWithPath: "/Applications/Chess.app")), "Chess")
        },
        TestCase(name: "activities saved with fewer fields still load") {
            let json = #"[{"title":"Water"},{"title":"Walk","symbol":"figure.walk","fit":"long","minutes":10},{"title":"Odd","fit":"someday"}]"#
            let list = try JSONDecoder().decode([BreakActivity].self, from: Data(json.utf8))
            try expectEqual(list.map(\.title), ["Water", "Walk", "Odd"])
            try expectEqual(list[0].symbol, "sparkles")
            try expect(list[0].isEnabled && list[0].fit == .any && list[0].minutes == nil)
            try expect(list[1].fit == .long && list[1].minutes == 10)
            try expect(list[2].fit == .any)
        },
        TestCase(name: "activities round-trip through JSON") {
            let original = BreakActivity(title: "Game", symbol: "gamecontroller.fill", note: "Quick", fit: .long, minutes: 15,
                                         opens: "/Applications/Chess.app", isEnabled: false)
            let decoded = try JSONDecoder().decode(BreakActivity.self, from: JSONEncoder().encode(original))
            try expectEqual(decoded, original)
        },
        TestCase(name: "default activities are valid") {
            let defaults = BreakActivities.defaults
            try expect(!BreakActivities.available(defaults, for: .shortBreak).isEmpty)
            try expect(!BreakActivities.available(defaults, for: .longBreak).isEmpty)
            try expect(defaults.allSatisfy { BreakActivities.symbols.contains($0.symbol) })
            try expectEqual(Set(defaults.map(\.id)).count, defaults.count)
        }
    ]
}
