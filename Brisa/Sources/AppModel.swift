import Foundation
import AppKit
import AVFoundation
import Combine
import UserNotifications
import SwiftUI

enum PomodoroPhase: String, CaseIterable, Codable {
    case work
    case shortBreak
    case longBreak

    var title: String {
        switch self {
        case .work: return "Focus"
        case .shortBreak: return "Short break"
        case .longBreak: return "Long break"
        }
    }

    var symbol: String {
        switch self {
        case .work: return "brain.head.profile"
        case .shortBreak: return "cup.and.saucer.fill"
        case .longBreak: return "leaf.fill"
        }
    }
}

/// How often and how recently a sound was started by the user.
struct SoundUsage: Codable, Equatable {
    var count: Int
    var last: Date
}

struct PomodoroSession: Codable, Identifiable, Equatable {
    var id = UUID()
    var end: Date
    var task: String
    var minutes: Int
}

struct PomodoroTask: Codable, Identifiable, Equatable {
    var id = UUID()
    var title: String
    var estimate = 1
    var completedSessions = 0
    var isDone = false
}

/// A curated blend for a Pomodoro phase. Weights are relative loudness (0...1); the phase volume scales them.
struct PomodoroSoundPreset: Identifiable {
    let id: String
    let name: String
    let icon: String
    let detail: String
    let weights: [String: Double]
}

extension PomodoroPhase {
    var presets: [PomodoroSoundPreset] {
        switch self {
        case .work: return [
            .init(id: "deep", name: "Deep focus", icon: "scope", detail: "Brown noise under light rain", weights: ["brown": 1, "rain": 0.6]),
            .init(id: "cafe", name: "Café hum", icon: "cup.and.saucer.fill", detail: "Busy room, soft rain", weights: ["coffeeShop": 1, "rain": 0.35]),
            .init(id: "steady", name: "Steady flow", icon: "wind", detail: "Pink noise with a fan", weights: ["pink": 0.9, "fan": 0.5]),
            .init(id: "rainy", name: "Rainy desk", icon: "cloud.rain", detail: "Tent rain, distant thunder", weights: ["tent": 1, "thunder": 0.35])
        ]
        case .shortBreak: return [
            .init(id: "ocean", name: "Ocean breeze", icon: "water.waves", detail: "Waves and a light wind", weights: ["ocean": 1, "wind": 0.5]),
            .init(id: "sunrise", name: "Sunrise", icon: "bird", detail: "Birdsong over a creek", weights: ["birds": 0.8, "creek": 0.7]),
            .init(id: "falls", name: "Waterfall", icon: "drop.fill", detail: "One continuous flow", weights: ["waterfall": 1])
        ]
        case .longBreak: return [
            .init(id: "fireside", name: "Fireside", icon: "flame.fill", detail: "Crackling fire, crickets", weights: ["realFireplace": 1, "night": 0.45]),
            .init(id: "beach", name: "Beach", icon: "beach.umbrella", detail: "Real waves and wind", weights: ["beachWaves": 1, "wind": 0.4]),
            .init(id: "storm", name: "Slow storm", icon: "cloud.bolt.rain", detail: "Heavy rain, rolling thunder", weights: ["heavy": 0.9, "thunder": 0.4])
        ]
        }
    }
}

/// The two values that change every second. They live apart from `AppModel` so a running timer only
/// redraws the views that show it, instead of every view that observes the model.
@MainActor
final class Countdown: ObservableObject {
    static let shared = Countdown()
    @Published var pomodoroRemainingSeconds = 25 * 60
    @Published var sleepRemainingSeconds = 0
}

/// Shows text that depends on the countdown; only this view redraws each second.
struct CountdownText: View {
    @ObservedObject private var countdown = Countdown.shared
    let text: () -> String
    init(_ text: @escaping () -> String) { self.text = text }
    var body: some View { Text(text()) }
}

@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()
    let inputSounds = InputSounds()

    @Published var levels: [String: Double] = [:]
    /// Stereo position of each playing sound, -1 (left) to 1 (right). Missing means centred.
    @Published var pans: [String: Double] = [:]
    @Published var favorites: Set<String> = []
    @Published var mixes: [Mix] = []
    @Published var importedSounds: [ImportedSound] = []
    @Published var isPlaying = false
    @Published var masterVolume = (UserDefaults.standard.object(forKey: "masterVolume") as? Double) ?? 0.65 {
        didSet { UserDefaults.standard.set(masterVolume, forKey: "masterVolume") }
    }
    /// Sleep timer. Counts down only while sounds play.
    var remainingSeconds: Int {
        get { Countdown.shared.sleepRemainingSeconds }
        set { Countdown.shared.sleepRemainingSeconds = max(0, newValue); synchronizeAudio() }
    }
    /// Seconds over which the sleep timer fades the sounds out.
    static let sleepFadeSeconds = 60
    static let sleepTimerOptions = [5, 15, 25, 30, 60, 90]
    @Published var error: String?
    @Published var pomodoroPhase: PomodoroPhase = .work { didSet { persistPomodoro() } }
    /// Not persisted on every tick: while running, the end date is what's saved.
    var pomodoroRemainingSeconds: Int {
        get { Countdown.shared.pomodoroRemainingSeconds }
        set { if Countdown.shared.pomodoroRemainingSeconds != newValue { Countdown.shared.pomodoroRemainingSeconds = newValue } }
    }
    @Published var isPomodoroRunning = false { didSet { persistPomodoro() } }
    @Published var completedPomodoros = 0 { didSet { persistPomodoro() } }
    @Published var workMinutes = 25 { didSet { let valid = min(max(workMinutes, 1), 180); if valid != workMinutes { workMinutes = valid } else { syncIdlePomodoro(); persistPomodoro() } } }
    @Published var shortBreakMinutes = 5 { didSet { let valid = min(max(shortBreakMinutes, 1), 60); if valid != shortBreakMinutes { shortBreakMinutes = valid } else { syncIdlePomodoro(); persistPomodoro() } } }
    @Published var longBreakMinutes = 15 { didSet { let valid = min(max(longBreakMinutes, 1), 120); if valid != longBreakMinutes { longBreakMinutes = valid } else { syncIdlePomodoro(); persistPomodoro() } } }
    @Published var longBreakInterval = 4 { didSet { let valid = min(max(longBreakInterval, 1), 12); if valid != longBreakInterval { longBreakInterval = valid } else { persistPomodoro() } } }
    @Published var pomodoroTotalSeconds = 25 * 60
    @Published var pomodoroTasks: [PomodoroTask] = [] { didSet { persistPomodoroTasks() } }
    @Published var activePomodoroTaskID: UUID? { didSet { persistPomodoro() } }
    @Published var autoStartPomodoro = false { didSet { persistPomodoro() } }
    @Published var pomodoroDailyGoal = 8 { didSet { let valid = min(max(pomodoroDailyGoal, 1), 24); if valid != pomodoroDailyGoal { pomodoroDailyGoal = valid } else { persistPomodoro() } } }
    @Published var pomodoroHistory: [PomodoroSession] = [] { didSet { persistPomodoroHistory() } }
    @Published var pomodoroConfetti = true { didSet { persistPomodoro() } }
    @Published var pomodoroChime = true { didSet { persistPomodoro() } }
    @Published var changesSoundscapeWithPomodoro = false { didSet { persistPomodoro() } }
    @Published var pomodoroSoundIDs: [String: String] = [:] { didSet { persistPomodoro() } }
    @Published var pomodoroSoundVolume = 0.05 { didSet { let valid = min(max(pomodoroSoundVolume, 0), 1); if valid != pomodoroSoundVolume { pomodoroSoundVolume = valid } else { persistPomodoro() } } }

    @Published var pausesOnSleep = (UserDefaults.standard.object(forKey: "pausesOnSleep") as? Bool) ?? true {
        didSet { UserDefaults.standard.set(pausesOnSleep, forKey: "pausesOnSleep") }
    }

    @Published var crossfadeEnabled = (UserDefaults.standard.object(forKey: "crossfade") as? Bool) ?? true {
        didSet { UserDefaults.standard.set(crossfadeEnabled, forKey: "crossfade"); audio.crossfadeEnabled = crossfadeEnabled }
    }
    @Published var livingMixEnabled = UserDefaults.standard.bool(forKey: "livingMix") {
        didSet { UserDefaults.standard.set(livingMixEnabled, forKey: "livingMix"); audio.livingDepth = livingDepth }
    }
    @Published var livingMixIntensity = LivingMix.Intensity(rawValue: UserDefaults.standard.string(forKey: "livingMixIntensity") ?? "") ?? .moderate {
        didSet { UserDefaults.standard.set(livingMixIntensity.rawValue, forKey: "livingMixIntensity"); audio.livingDepth = livingDepth }
    }
    private var livingDepth: Double { livingMixEnabled ? livingMixIntensity.depth : 0 }
    @Published private(set) var soundUsage: [String: SoundUsage] = [:]
    /// A mix that arrived from a file or link and is waiting for the user to confirm.
    @Published var pendingSharedMix: SharedMix?
    var isAutomaticChange = false
    /// What a Focus filter turned on, so only that is stopped when the Focus ends.
    var focusStartedSounds = false
    var focusStartedSession = false
    @Published var routines: [Routine] = [] { didSet { persistRoutines() } }
    @Published var modes: [BrisaMode] = [] { didSet { persistModes() } }
    @Published var activeModeID: UUID? { didSet { UserDefaults.standard.set(activeModeID?.uuidString, forKey: "activeMode") } }
    /// Distracting apps the active mode hid, shown again when it ends.
    var hiddenByMode: Set<String> = [] { didSet { UserDefaults.standard.set(Array(hiddenByMode), forKey: "hiddenByMode") } }
    var lastRoutineCheck = Date()
    var lastRoutineCheckSaved = Date.distantPast

    private var volumeBeforeMute = 0.65
    private var resumeAfterWake = false
    private var integration: SystemIntegration?
    private let audio = AudioBank()
    private var timer: Timer?
    private var pomodoroEndDate: Date?
    private var isRestoringPomodoro = false

    init() {
        levels = UserDefaults.standard.dictionary(forKey: "levels") as? [String: Double] ?? [:]
        pans = UserDefaults.standard.dictionary(forKey: "pans") as? [String: Double] ?? [:]
        favorites = Set(UserDefaults.standard.stringArray(forKey: "favorites") ?? [])
        if let data = UserDefaults.standard.data(forKey: "mixes"),
           let savedMixes = try? JSONDecoder().decode([Mix].self, from: data) {
            mixes = savedMixes
        }
        if let data = UserDefaults.standard.data(forKey: "importedSounds"),
           let savedSounds = try? JSONDecoder().decode([ImportedSound].self, from: data) {
            importedSounds = savedSounds
        }
        if let data = UserDefaults.standard.data(forKey: "soundUsage"),
           let saved = try? JSONDecoder().decode([String: SoundUsage].self, from: data) {
            soundUsage = saved
        }
        audio.crossfadeEnabled = crossfadeEnabled
        audio.livingDepth = livingDepth
        loadRoutines()
        audio.onBufferReady = { [weak self] error in
            MainActor.assumeIsolated {
                guard let self else { return }
                if let error { self.error = error.localizedDescription } else { self.synchronizeAudio() }
            }
        }
        loadModes()
        audio.importedURL = { [weak self] id in self?.importedSounds.first(where: { $0.id == id }).flatMap { $0.storedFile }.map(URL.init(fileURLWithPath:)) }
        volumeBeforeMute = masterVolume > 0 ? masterVolume : 0.65
        restorePomodoro()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let model = self else { return }
            Task { @MainActor [weak model] in model?.tickTimer() }
        }
        NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: audio.engine, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.recoverAudioEngine() }
        }
        integration = SystemIntegration(model: self)
        BrisaIntegration.refreshShortcutPhrases()
        YouTubeVideoPlayer.shared.onTitle = { [weak self] id, title in self?.updateVideoTitle(soundID: id, title: title) }
        synchronizeAudio()
    }

    /// Rebuilds playback after the output device changes (headphones unplugged, AirPods connected, wake from sleep).
    func recoverAudioEngine() {
        audio.reset()
        synchronizeAudio()
    }

    func systemWillSleep() {
        guard pausesOnSleep, isPlaying else { return }
        resumeAfterWake = true
        isPlaying = false
        synchronizeAudio()
    }

    func systemDidWake() {
        let shouldResume = resumeAfterWake
        resumeAfterWake = false
        if shouldResume { isPlaying = true }
        // The output device can change while asleep, so always rebuild the engine before playing again.
        recoverAudioEngine()
    }

    func toggle(_ soundID: String) {
        if levels[soundID] != nil { levels.removeValue(forKey: soundID) }
        else { levels[soundID] = 0.05; isPlaying = true; recordUsage([soundID]) }
        if levels.isEmpty { isPlaying = false }
        synchronizeAudio()
    }

    /// Counts a sound each time you start it yourself; automatic changes (Pomodoro phases) don't count.
    func recordUsage(_ ids: some Sequence<String>) {
        guard !isAutomaticChange else { return }
        let now = Date()
        for id in ids {
            var entry = soundUsage[id] ?? SoundUsage(count: 0, last: now)
            entry.count += 1
            entry.last = now
            soundUsage[id] = entry
        }
        if let data = try? JSONEncoder().encode(soundUsage) { UserDefaults.standard.set(data, forKey: "soundUsage") }
    }

    /// Sounds you played most recently, newest first.
    var recentSounds: [Sound] {
        let known = Dictionary(uniqueKeysWithValues: availableLibrary.map { ($0.id, $0) })
        return soundUsage.sorted { $0.value.last > $1.value.last }.compactMap { known[$0.key] }
    }

    /// Sounds you play most often; ties go to the more recent one. Sounds played once are not "most used" yet.
    var mostUsedSounds: [Sound] {
        let known = Dictionary(uniqueKeysWithValues: availableLibrary.map { ($0.id, $0) })
        return soundUsage.filter { $0.value.count >= 2 }
            .sorted { ($0.value.count, $0.value.last) > ($1.value.count, $1.value.last) }
            .compactMap { known[$0.key] }
    }

    func togglePlayback() {
        if levels.isEmpty { levels["rain"] = 0.05 }
        isPlaying.toggle()
        synchronizeAudio()
    }

    func setFavorite(_ soundID: String) {
        if favorites.contains(soundID) { favorites.remove(soundID) }
        else { favorites.insert(soundID) }
        UserDefaults.standard.set(Array(favorites), forKey: "favorites")
    }

    func applyMix(_ levels: [String: Double], pans: [String: Double] = [:]) { self.levels = levels; self.pans = pans; isPlaying = true; recordUsage(levels.keys); synchronizeAudio() }
    func applyMix(_ mix: Mix) { applyMix(mix.levels, pans: mix.pans) }
    func replaceWith(_ sound: Sound) { levels = [sound.id: 0.05]; pans = [:]; isPlaying = true; recordUsage([sound.id]); synchronizeAudio() }
    func saveMix(named name: String) { mixes.append(Mix(name: name, levels: levels, pans: pans)); persistMixes() }
    func setPan(_ pan: Double, for soundID: String) {
        let clamped = min(max(pan, -1), 1)
        // Snap near the middle so "centre" is easy to hit with a slider.
        pans[soundID] = abs(clamped) < 0.04 ? nil : clamped
        synchronizeAudio()
    }
    func persistMixes() {
        if let data = try? JSONEncoder().encode(mixes) { UserDefaults.standard.set(data, forKey: "mixes") }
        // Lets Siri and Spotlight offer "Play <mix name> in Brisa" for the current mixes.
        BrisaIntegration.refreshShortcutPhrases()
    }
    func persistImportedSounds() { if let data = try? JSONEncoder().encode(importedSounds) { UserDefaults.standard.set(data, forKey: "importedSounds") } }

    /// Sounds that can go into a mix. YouTube videos are played by the video window, never mixed.
    var availableLibrary: [Sound] { library + importedSounds.filter { $0.source != .youtube }.map(\.sound) }
    var youtubeVideos: [ImportedSound] { importedSounds.filter { $0.source == .youtube && $0.youtubeID != nil }.sorted { $0.importedAt > $1.importedAt } }

    func importLocalFile(_ url: URL, attribution: String = "", license: String = "") throws {
        guard ImportedSoundStore.isSupported(url) else { throw AudioImportError.unsupportedFormat }
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size <= ImportedSoundStore.maximumFileSize else { throw AudioImportError.fileTooLarge }
        try ImportedSoundStore.prepareDirectory()
        let id = "imported-\(UUID().uuidString)"
        let destination = ImportedSoundStore.makeStoredURL(id: id, sourceURL: url)
        try FileManager.default.copyItem(at: url, to: destination)
        let bookmark = try? url.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)
        importedSounds.append(ImportedSound(id: id, name: url.deletingPathExtension().lastPathComponent, source: .localFile,
                                            originalURL: url.absoluteString, storedFile: destination.path, bookmark: bookmark,
                                            attribution: attribution, license: license, importedAt: .now, unavailableReason: nil))
        persistImportedSounds()
    }

    func importExternalURL(_ rawURL: String, attribution: String = "", license: String = "") async throws {
        guard let url = URL(string: rawURL), url.scheme?.lowercased() == "https" else { throw AudioImportError.invalidURL }
        if ImportedSoundStore.isYouTube(url) {
            try await importYouTubeLink(url, attribution: attribution, license: license)
            return
        }
        let (temporaryURL, response) = try await URLSession.shared.download(from: url)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode), http.url?.scheme?.lowercased() == "https" else { throw AudioImportError.downloadFailed }
        let contentType = http.value(forHTTPHeaderField: "Content-Type")?.lowercased() ?? ""
        let resolvedExtension = ImportedSoundStore.isSupported(http.url ?? url) ? (http.url ?? url).pathExtension.lowercased() : ImportedSoundStore.fileExtension(for: contentType)
        guard let resolvedExtension, ImportedSoundStore.supportedExtensions.contains(resolvedExtension),
              ImportedSoundStore.fileExtension(for: contentType) != nil || (contentType.split(separator: ";").first == "application/octet-stream" && ImportedSoundStore.isSupported(http.url ?? url)) else { throw AudioImportError.unsafeResponse }
        let size = (try? temporaryURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size <= ImportedSoundStore.maximumFileSize else { throw AudioImportError.fileTooLarge }
        try ImportedSoundStore.prepareDirectory()
        let id = "imported-\(UUID().uuidString)"
        let destination = ImportedSoundStore.makeStoredURL(id: id, sourceURL: URL(fileURLWithPath: "audio.\(resolvedExtension)"))
        try FileManager.default.moveItem(at: temporaryURL, to: destination)
        let fallbackName = url.deletingPathExtension().lastPathComponent
        importedSounds.append(ImportedSound(id: id, name: fallbackName.isEmpty ? "External audio" : fallbackName, source: .externalURL,
                                            originalURL: url.absoluteString, storedFile: destination.path, bookmark: nil,
                                            attribution: attribution, license: license, importedAt: .now, unavailableReason: nil))
        persistImportedSounds()
    }

    private func importYouTubeLink(_ url: URL, attribution: String, license: String) async throws {
        guard let videoID = YouTubeLink.videoID(from: url.absoluteString) else { throw AudioImportError.notAVideo }
        guard !importedSounds.contains(where: { $0.source == .youtube && $0.youtubeID == videoID }) else { throw AudioImportError.duplicateVideo }
        let metadata = await YouTubeLink.fetchMetadata(for: videoID)   // nil offline or for private videos: the card still works
        importedSounds.append(ImportedSound(
            id: "imported-\(UUID().uuidString)", name: metadata?.title ?? "YouTube video", source: .youtube,
            originalURL: YouTubeLink.watchURL(videoID).absoluteString, storedFile: nil, bookmark: nil,
            attribution: attribution.isEmpty ? (metadata?.channel ?? "") : attribution, license: license, importedAt: .now,
            unavailableReason: nil, videoID: videoID, thumbnailURL: metadata?.thumbnail))
        persistImportedSounds()
    }

    /// The player reports the real title; use it for links saved before titles were fetched.
    func updateVideoTitle(soundID: String, title: String) {
        guard let index = importedSounds.firstIndex(where: { $0.id == soundID }),
              ["YouTube video", "YouTube source"].contains(importedSounds[index].name) else { return }
        importedSounds[index].name = title
        persistImportedSounds()
    }

    func removeImportedSound(_ sound: ImportedSound) {
        if sound.source == .youtube, YouTubeVideoPlayer.shared.isCurrent(sound) { YouTubeVideoPlayer.shared.stop() }
        levels.removeValue(forKey: sound.id)
        audio.discardBuffer(for: sound.id)
        if let path = sound.storedFile { try? FileManager.default.removeItem(atPath: path) }
        importedSounds.removeAll { $0.id == sound.id }
        persistImportedSounds(); synchronizeAudio()
    }

    func relink(_ sound: ImportedSound, to url: URL) throws {
        guard ImportedSoundStore.isSupported(url) else { throw AudioImportError.unsupportedFormat }
        guard let index = importedSounds.firstIndex(where: { $0.id == sound.id }) else { return }
        try ImportedSoundStore.prepareDirectory()
        let destination = ImportedSoundStore.makeStoredURL(id: sound.id, sourceURL: url)
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.copyItem(at: url, to: destination)
        importedSounds[index].storedFile = destination.path
        importedSounds[index].bookmark = try? url.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)
        importedSounds[index].unavailableReason = nil
        audio.discardBuffer(for: sound.id); persistImportedSounds()
    }

    func toggleMute() {
        if masterVolume > 0 { volumeBeforeMute = masterVolume; masterVolume = 0 }
        else { masterVolume = volumeBeforeMute }
        synchronizeAudio()
    }

    var pomodoroDurationSeconds: Int {
        switch pomodoroPhase {
        case .work: return workMinutes * 60
        case .shortBreak: return shortBreakMinutes * 60
        case .longBreak: return longBreakMinutes * 60
        }
    }

    var pomodoroProgress: Double {
        guard pomodoroTotalSeconds > 0 else { return 0 }
        return min(max(1 - Double(pomodoroRemainingSeconds) / Double(pomodoroTotalSeconds), 0), 1)
    }

    /// Focus sessions finished in the current long-break cycle (drives the dots).
    var pomodoroCycleProgress: Int {
        pomodoroPhase == .longBreak ? longBreakInterval : completedPomodoros % longBreakInterval
    }

    var pomodoroSessionsToday: [PomodoroSession] {
        pomodoroHistory.filter { Calendar.current.isDateInToday($0.end) }
    }

    var focusMinutesToday: Int { pomodoroSessionsToday.reduce(0) { $0 + $1.minutes } }
    var totalFocusMinutes: Int { pomodoroHistory.reduce(0) { $0 + $1.minutes } }

    /// Consecutive days with at least one focus session, counting back from today (or yesterday if today is still empty).
    var pomodoroStreak: Int {
        let calendar = Calendar.current
        let days = Set(pomodoroHistory.map { calendar.startOfDay(for: $0.end) })
        var day = calendar.startOfDay(for: Date())
        if !days.contains(day) { day = calendar.date(byAdding: .day, value: -1, to: day) ?? day }
        var streak = 0
        while days.contains(day) {
            streak += 1
            day = calendar.date(byAdding: .day, value: -1, to: day) ?? .distantPast
        }
        return streak
    }

    /// Focus minutes per day for the last 7 days, oldest first.
    var pomodoroWeek: [(date: Date, minutes: Int)] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        return (0..<7).reversed().compactMap { offset in
            guard let day = calendar.date(byAdding: .day, value: -offset, to: today) else { return nil }
            let minutes = pomodoroHistory.filter { calendar.isDate($0.end, inSameDayAs: day) }.reduce(0) { $0 + $1.minutes }
            return (day, minutes)
        }
    }

    var activePomodoroTask: PomodoroTask? { pomodoroTasks.first { $0.id == activePomodoroTaskID } }

    func addPomodoroTask(_ title: String, estimate: Int = 1) {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        let task = PomodoroTask(title: title, estimate: estimate)
        pomodoroTasks.append(task)
        if activePomodoroTaskID == nil { activePomodoroTaskID = task.id }
    }

    func selectPomodoroTask(_ id: UUID?) {
        guard id == nil || pomodoroTasks.contains(where: { $0.id == id && !$0.isDone }) else { return }
        activePomodoroTaskID = id
    }

    func togglePomodoroTaskDone(_ id: UUID) {
        guard let index = pomodoroTasks.firstIndex(where: { $0.id == id }) else { return }
        pomodoroTasks[index].isDone.toggle()
        if pomodoroTasks[index].isDone, activePomodoroTaskID == id {
            activePomodoroTaskID = pomodoroTasks.first { !$0.isDone }?.id
        } else if activePomodoroTaskID == nil, !pomodoroTasks[index].isDone {
            activePomodoroTaskID = id
        }
    }

    func setPomodoroTaskEstimate(_ id: UUID, _ estimate: Int) {
        guard let index = pomodoroTasks.firstIndex(where: { $0.id == id }) else { return }
        pomodoroTasks[index].estimate = min(max(estimate, 1), 12)
    }

    func removePomodoroTask(_ id: UUID) {
        pomodoroTasks.removeAll { $0.id == id }
        if activePomodoroTaskID == id { activePomodoroTaskID = pomodoroTasks.first { !$0.isDone }?.id }
    }

    func renamePomodoroTask(_ id: UUID, to title: String) {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, let index = pomodoroTasks.firstIndex(where: { $0.id == id }) else { return }
        pomodoroTasks[index].title = title
    }

    /// Moves an open task up (-1) or down (+1) among the open tasks.
    func movePomodoroTask(_ id: UUID, by offset: Int) {
        let open = pomodoroTasks.indices.filter { !pomodoroTasks[$0].isDone }
        guard let position = open.firstIndex(where: { pomodoroTasks[$0].id == id }) else { return }
        let target = position + offset
        guard open.indices.contains(target) else { return }
        pomodoroTasks.swapAt(open[position], open[target])
    }

    /// Drag and drop: puts `id` right before `targetID`.
    func movePomodoroTask(_ id: UUID, before targetID: UUID) {
        guard id != targetID, let from = pomodoroTasks.firstIndex(where: { $0.id == id }),
              pomodoroTasks.contains(where: { $0.id == targetID }) else { return }
        let moved = pomodoroTasks.remove(at: from)
        let to = pomodoroTasks.firstIndex(where: { $0.id == targetID }) ?? pomodoroTasks.endIndex
        pomodoroTasks.insert(moved, at: to)
    }

    func clearCompletedPomodoroTasks() {
        pomodoroTasks.removeAll { $0.isDone }
    }

    func clearPomodoroHistory() { pomodoroHistory = [] }

    var pomodoroTimeText: String {
        String(format: "%02d:%02d", max(0, pomodoroRemainingSeconds) / 60, max(0, pomodoroRemainingSeconds) % 60)
    }

    func startPomodoro() {
        if pomodoroRemainingSeconds <= 0 {
            pomodoroTotalSeconds = pomodoroDurationSeconds
            pomodoroRemainingSeconds = pomodoroTotalSeconds
        }
        pomodoroEndDate = Date().addingTimeInterval(TimeInterval(pomodoroRemainingSeconds))
        isPomodoroRunning = true
        persistPomodoro()
    }

    func pausePomodoro() {
        updatePomodoroRemaining()
        pomodoroEndDate = nil
        isPomodoroRunning = false
        persistPomodoro()
    }

    func resetPomodoro() {
        pomodoroEndDate = nil
        isPomodoroRunning = false
        pomodoroPhase = .work
        pomodoroTotalSeconds = workMinutes * 60
        pomodoroRemainingSeconds = pomodoroTotalSeconds
        persistPomodoro()
    }

    func selectPomodoroPhase(_ phase: PomodoroPhase) {
        guard !isPomodoroRunning, phase != pomodoroPhase else { return }
        pomodoroPhase = phase
        pomodoroTotalSeconds = pomodoroDurationSeconds
        pomodoroRemainingSeconds = pomodoroTotalSeconds
        persistPomodoro()
    }

    var pomodoroMinutesRange: ClosedRange<Int> {
        switch pomodoroPhase {
        case .work: return 1...180
        case .shortBreak: return 1...60
        case .longBreak: return 1...120
        }
    }

    /// Sets the length of the current phase; also becomes the default for that phase.
    func setPomodoroMinutes(_ minutes: Int) {
        let valid = min(max(minutes, pomodoroMinutesRange.lowerBound), pomodoroMinutesRange.upperBound)
        switch pomodoroPhase {
        case .work: workMinutes = valid
        case .shortBreak: shortBreakMinutes = valid
        case .longBreak: longBreakMinutes = valid
        }
        pomodoroTotalSeconds = valid * 60
        pomodoroRemainingSeconds = valid * 60
        if isPomodoroRunning { pomodoroEndDate = Date().addingTimeInterval(TimeInterval(valid * 60)) }
        persistPomodoro()
    }

    func extendPomodoro(minutes: Int = 5) {
        let extra = max(minutes * 60, 60 - pomodoroRemainingSeconds)
        pomodoroTotalSeconds += extra
        pomodoroRemainingSeconds += extra
        pomodoroEndDate = pomodoroEndDate?.addingTimeInterval(TimeInterval(extra))
        persistPomodoro()
    }

    private func syncIdlePomodoro() {
        guard !isRestoringPomodoro, !isPomodoroRunning, pomodoroRemainingSeconds == pomodoroTotalSeconds else { return }
        pomodoroTotalSeconds = pomodoroDurationSeconds
        pomodoroRemainingSeconds = pomodoroTotalSeconds
    }

    func skipPomodoro() {
        advancePomodoro(completed: false)
    }

    func pomodoroLevels(for preset: PomodoroSoundPreset) -> [String: Double] {
        let available = Set(availableLibrary.map(\.id))
        return preset.weights.filter { available.contains($0.key) }.mapValues { min($0 * pomodoroSoundVolume, 1) }
    }

    func applyPomodoroPreset(_ preset: PomodoroSoundPreset) {
        let levels = pomodoroLevels(for: preset)
        guard !levels.isEmpty else { return }
        applyMix(levels)
    }

    func isPomodoroPresetPlaying(_ preset: PomodoroSoundPreset) -> Bool {
        isPlaying && levels == pomodoroLevels(for: preset)
    }

    /// Plays what the user picked for the current phase: a preset ("preset:id"), one of their saved mixes ("mix:uuid"),
    /// a single sound (its id), or — when empty — the first suggested preset for the phase.
    func applyPomodoroSoundscape() {
        guard changesSoundscapeWithPomodoro else { return }
        isAutomaticChange = true   // phase changes should not inflate "Most used"
        defer { isAutomaticChange = false }
        let choice = pomodoroSoundIDs[pomodoroPhase.rawValue] ?? ""
        if choice.hasPrefix("mix:"), let mix = mixes.first(where: { "mix:\($0.id.uuidString)" == choice }) {
            applyMix(mix)
        } else if choice.hasPrefix("preset:"), let preset = pomodoroPhase.presets.first(where: { "preset:\($0.id)" == choice }) {
            applyPomodoroPreset(preset)
        } else if !choice.isEmpty, availableLibrary.contains(where: { $0.id == choice }) {
            applyMix([choice: pomodoroSoundVolume])
        } else if let preset = pomodoroPhase.presets.first {
            applyPomodoroPreset(preset)
        }
    }

    func pomodoroSoundID(for phase: PomodoroPhase) -> String {
        pomodoroSoundIDs[phase.rawValue] ?? ""
    }

    func setPomodoroSoundID(_ id: String, for phase: PomodoroPhase) {
        pomodoroSoundIDs[phase.rawValue] = id
    }

    func synchronizeAudio() {
        let placed = pans.filter { levels[$0.key] != nil }
        if placed.count != pans.count { pans = placed }
        do { try audio.update(levels, pans: pans, playing: isPlaying, master: effectiveMasterVolume) }
        catch { self.error = error.localizedDescription; isPlaying = false }
        UserDefaults.standard.set(levels, forKey: "levels")
        UserDefaults.standard.set(pans, forKey: "pans")
        integration?.refreshNowPlaying()
    }

    /// The master volume, lowered while the sleep timer fades out, so moving the slider never undoes the fade.
    var effectiveMasterVolume: Double {
        let left = remainingSeconds
        guard left > 0, left < Self.sleepFadeSeconds else { return masterVolume }
        return masterVolume * Double(left) / Double(Self.sleepFadeSeconds)
    }

    var nowPlayingTitle: String {
        let names = levels.keys.sorted().compactMap { id in availableLibrary.first(where: { $0.id == id })?.name }
        return names.isEmpty ? "No sounds selected" : names.prefix(2).joined(separator: " + ")
    }

    private func tickTimer() {
        if remainingSeconds > 0, isPlaying {
            let left = remainingSeconds - 1
            Countdown.shared.sleepRemainingSeconds = left
            if left == 0 { isPlaying = false; synchronizeAudio() }
            else if left <= Self.sleepFadeSeconds { audio.setMasterVolume(effectiveMasterVolume) }
        }

        updatePomodoroRemaining()
        checkRoutines()
    }

    private func updatePomodoroRemaining() {
        guard isPomodoroRunning, let pomodoroEndDate else { return }
        let seconds = max(0, Int(pomodoroEndDate.timeIntervalSinceNow.rounded(.up)))
        if seconds != pomodoroRemainingSeconds { pomodoroRemainingSeconds = seconds }
        if seconds == 0 { advancePomodoro(completed: true) }
    }

    private func advancePomodoro(completed: Bool) {
        let finished = pomodoroPhase
        let wasRunning = isPomodoroRunning
        // The cycle position advances on skip too, so 25/5/25/5… always reaches the long break.
        if finished == .work { completedPomodoros += 1; BreakStore.shared.clearCurrent() }
        if completed && finished == .work {
            let task = activePomodoroTask?.title ?? ""
            if let index = pomodoroTasks.firstIndex(where: { $0.id == activePomodoroTaskID }) { pomodoroTasks[index].completedSessions += 1 }
            pomodoroHistory.append(PomodoroSession(end: Date(), task: task, minutes: max(1, Int((Double(pomodoroTotalSeconds) / 60).rounded()))))
            if pomodoroHistory.count > 500 { pomodoroHistory.removeFirst(pomodoroHistory.count - 500) }
        }
        if finished == .work {
            pomodoroPhase = completedPomodoros > 0 && completedPomodoros % longBreakInterval == 0 ? .longBreak : .shortBreak
        } else {
            pomodoroPhase = .work
        }
        pomodoroTotalSeconds = pomodoroDurationSeconds
        pomodoroRemainingSeconds = pomodoroTotalSeconds
        pomodoroEndDate = nil
        isPomodoroRunning = false
        applyPomodoroSoundscape()
        if completed ? autoStartPomodoro : wasRunning { startPomodoro() }
        if completed {
            // The break screen says the same as the notification, so only one of them appears.
            let screenShown = !isRestoringPomodoro && BreakScreen.shared.phaseEnded(from: finished)
            if !screenShown { notifyPomodoroTransition(from: finished, to: pomodoroPhase) }
            if !isRestoringPomodoro { celebratePhaseEnd(finished) }
        }
        persistPomodoro()
    }

    /// Gives the current phase a new length without changing the default, keeping the time already spent.
    func resizeCurrentPhase(minutes: Int) {
        let total = min(max(minutes, 1), 180) * 60
        let elapsed = max(0, pomodoroTotalSeconds - pomodoroRemainingSeconds)
        pomodoroRemainingSeconds = max(total - elapsed, 60)
        pomodoroTotalSeconds = max(total, elapsed + pomodoroRemainingSeconds)
        if isPomodoroRunning { pomodoroEndDate = Date().addingTimeInterval(TimeInterval(pomodoroRemainingSeconds)) }
        persistPomodoro()
    }

    /// Goes back to a break that just ended for a few more minutes, from the break screen.
    func returnToBreak(_ phase: PomodoroPhase, minutes: Int) {
        guard phase != .work else { return }
        pomodoroEndDate = nil
        isPomodoroRunning = false
        pomodoroPhase = phase
        pomodoroTotalSeconds = max(minutes, 1) * 60
        pomodoroRemainingSeconds = pomodoroTotalSeconds
        applyPomodoroSoundscape()
        startPomodoro()
    }

    private func restorePomodoro() {
        isRestoringPomodoro = true
        defer { isRestoringPomodoro = false; persistPomodoro() }
        let defaults = UserDefaults.standard
        workMinutes = defaults.object(forKey: "pomodoro.workMinutes") as? Int ?? 25
        shortBreakMinutes = defaults.object(forKey: "pomodoro.shortBreakMinutes") as? Int ?? 5
        longBreakMinutes = defaults.object(forKey: "pomodoro.longBreakMinutes") as? Int ?? 15
        longBreakInterval = defaults.object(forKey: "pomodoro.longBreakInterval") as? Int ?? 4
        changesSoundscapeWithPomodoro = defaults.bool(forKey: "pomodoro.changesSoundscape")
        pomodoroSoundIDs = defaults.dictionary(forKey: "pomodoro.soundIDs") as? [String: String] ?? [:]
        pomodoroSoundVolume = defaults.object(forKey: "pomodoro.soundVolume") as? Double ?? 0.05
        completedPomodoros = defaults.integer(forKey: "pomodoro.completed")
        if let data = defaults.data(forKey: "pomodoro.tasks"),
           let saved = try? JSONDecoder().decode([PomodoroTask].self, from: data) {
            pomodoroTasks = saved
        }
        activePomodoroTaskID = defaults.string(forKey: "pomodoro.activeTask").flatMap(UUID.init(uuidString:)).flatMap { id in pomodoroTasks.contains { $0.id == id && !$0.isDone } ? id : nil }
        autoStartPomodoro = defaults.bool(forKey: "pomodoro.autoStart")
        pomodoroConfetti = defaults.object(forKey: "pomodoro.confetti") as? Bool ?? true
        pomodoroChime = defaults.object(forKey: "pomodoro.chime") as? Bool ?? true
        pomodoroDailyGoal = defaults.object(forKey: "pomodoro.dailyGoal") as? Int ?? 8
        if let data = defaults.data(forKey: "pomodoro.history"),
           let saved = try? JSONDecoder().decode([PomodoroSession].self, from: data) {
            pomodoroHistory = saved
        }
        pomodoroPhase = PomodoroPhase(rawValue: defaults.string(forKey: "pomodoro.phase") ?? "") ?? .work
        pomodoroRemainingSeconds = defaults.object(forKey: "pomodoro.remaining") as? Int ?? pomodoroDurationSeconds
        pomodoroTotalSeconds = max(defaults.object(forKey: "pomodoro.total") as? Int ?? pomodoroDurationSeconds, pomodoroRemainingSeconds, 1)
        if let end = defaults.object(forKey: "pomodoro.end") as? Double {
            let endDate = Date(timeIntervalSince1970: end)
            if endDate > Date() {
                pomodoroEndDate = endDate
                isPomodoroRunning = true
                updatePomodoroRemaining()
            } else if defaults.bool(forKey: "pomodoro.running") {
                pomodoroEndDate = Date()
                isPomodoroRunning = true
                advancePomodoro(completed: true)
            }
        }
    }

    private func persistPomodoro() {
        guard !isRestoringPomodoro else { return }
        let defaults = UserDefaults.standard
        defaults.set(pomodoroPhase.rawValue, forKey: "pomodoro.phase")
        defaults.set(pomodoroRemainingSeconds, forKey: "pomodoro.remaining")
        defaults.set(isPomodoroRunning, forKey: "pomodoro.running")
        defaults.set(completedPomodoros, forKey: "pomodoro.completed")
        defaults.set(workMinutes, forKey: "pomodoro.workMinutes")
        defaults.set(shortBreakMinutes, forKey: "pomodoro.shortBreakMinutes")
        defaults.set(longBreakMinutes, forKey: "pomodoro.longBreakMinutes")
        defaults.set(longBreakInterval, forKey: "pomodoro.longBreakInterval")
        defaults.set(changesSoundscapeWithPomodoro, forKey: "pomodoro.changesSoundscape")
        defaults.set(pomodoroSoundIDs, forKey: "pomodoro.soundIDs")
        defaults.set(pomodoroSoundVolume, forKey: "pomodoro.soundVolume")
        defaults.set(pomodoroTotalSeconds, forKey: "pomodoro.total")
        defaults.set(activePomodoroTaskID?.uuidString, forKey: "pomodoro.activeTask")
        defaults.set(autoStartPomodoro, forKey: "pomodoro.autoStart")
        defaults.set(pomodoroConfetti, forKey: "pomodoro.confetti")
        defaults.set(pomodoroChime, forKey: "pomodoro.chime")
        defaults.set(pomodoroDailyGoal, forKey: "pomodoro.dailyGoal")
        defaults.set(pomodoroEndDate?.timeIntervalSince1970, forKey: "pomodoro.end")
    }

    private func persistPomodoroTasks() {
        guard !isRestoringPomodoro, let data = try? JSONEncoder().encode(pomodoroTasks) else { return }
        UserDefaults.standard.set(data, forKey: "pomodoro.tasks")
    }

    private func persistPomodoroHistory() {
        guard !isRestoringPomodoro, let data = try? JSONEncoder().encode(pomodoroHistory) else { return }
        UserDefaults.standard.set(data, forKey: "pomodoro.history")
    }

    func celebratePhaseEnd(_ finished: PomodoroPhase) {
        if pomodoroChime, let sound = NSSound(named: finished == .work ? "Hero" : "Ping") {
            sound.volume = 0.6
            sound.play()
        }
        if pomodoroConfetti { PomodoroCelebration.shared.play() }
    }

    private func notifyPomodoroTransition(from finished: PomodoroPhase, to next: PomodoroPhase) {
        let content = UNMutableNotificationContent()
        content.title = finished == .work ? "Focus session complete" : "Break complete"
        content.body = next == .work ? "Time to focus again." : "Take a \(next.title.lowercased())."
        content.sound = nil   // the chime is played by Brisa itself so it can be turned off
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }
}
