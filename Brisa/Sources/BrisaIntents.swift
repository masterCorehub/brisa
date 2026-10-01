import AppIntents
import Foundation
import Security

// Actions for the Shortcuts app, Siri and Spotlight, plus a Focus filter.
// `Scripts/build.sh` runs Apple's metadata processor so the system can find them.

// MARK: - Entities

struct MixEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Mix"
    static let defaultQuery = MixQuery()

    let id: UUID
    let name: String

    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)") }

    init(_ mix: Mix) { id = mix.id; name = mix.name }
}

struct MixQuery: EntityStringQuery {
    @MainActor func entities(for identifiers: [UUID]) async throws -> [MixEntity] {
        AppModel.shared.mixes.filter { identifiers.contains($0.id) }.map(MixEntity.init)
    }

    @MainActor func suggestedEntities() async throws -> [MixEntity] {
        AppModel.shared.mixes.map(MixEntity.init)
    }

    @MainActor func entities(matching string: String) async throws -> [MixEntity] {
        AppModel.shared.mixes.filter { $0.name.localizedCaseInsensitiveContains(string) }.map(MixEntity.init)
    }
}

struct SoundEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Sound"
    static let defaultQuery = SoundQuery()

    let id: String
    let name: String
    let category: String

    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)", subtitle: "\(category)") }

    init(_ sound: Sound) { id = sound.id; name = sound.name; category = sound.category }
}

struct SoundQuery: EntityStringQuery {
    @MainActor func entities(for identifiers: [String]) async throws -> [SoundEntity] {
        AppModel.shared.availableLibrary.filter { identifiers.contains($0.id) }.map(SoundEntity.init)
    }

    @MainActor func suggestedEntities() async throws -> [SoundEntity] {
        AppModel.shared.availableLibrary.map(SoundEntity.init)
    }

    @MainActor func entities(matching string: String) async throws -> [SoundEntity] {
        AppModel.shared.availableLibrary.filter { $0.name.localizedCaseInsensitiveContains(string) }.map(SoundEntity.init)
    }
}

struct ModeEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Mode"
    static let defaultQuery = ModeQuery()

    let id: UUID
    let name: String

    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)") }

    init(_ mode: BrisaMode) { id = mode.id; name = mode.name }
}

struct ModeQuery: EntityStringQuery {
    @MainActor func entities(for identifiers: [UUID]) async throws -> [ModeEntity] {
        AppModel.shared.modes.filter { identifiers.contains($0.id) }.map(ModeEntity.init)
    }

    @MainActor func suggestedEntities() async throws -> [ModeEntity] {
        AppModel.shared.modes.map(ModeEntity.init)
    }

    @MainActor func entities(matching string: String) async throws -> [ModeEntity] {
        AppModel.shared.modes.filter { $0.name.localizedCaseInsensitiveContains(string) }.map(ModeEntity.init)
    }
}

enum BrisaIntentError: Error, CustomLocalizedStringResourceConvertible {
    case mixNotFound, soundNotFound, modeNotFound

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .mixNotFound: return "That mix no longer exists in Brisa."
        case .soundNotFound: return "That sound is no longer in Brisa's library."
        case .modeNotFound: return "That mode no longer exists in Brisa."
        }
    }
}

// MARK: - Sounds

struct PlayMixIntent: AppIntent {
    static let title: LocalizedStringResource = "Play Mix"
    static let description = IntentDescription("Plays one of your saved Brisa mixes.")

    @Parameter(title: "Mix") var mix: MixEntity

    static var parameterSummary: some ParameterSummary { Summary("Play \(\.$mix)") }

    @MainActor func perform() async throws -> some IntentResult & ProvidesDialog {
        let model = AppModel.shared
        guard let saved = model.mixes.first(where: { $0.id == mix.id }) else { throw BrisaIntentError.mixNotFound }
        model.applyMix(saved)
        return .result(dialog: "Playing \(saved.name).")
    }
}

struct PlaySoundIntent: AppIntent {
    static let title: LocalizedStringResource = "Play Sound"
    static let description = IntentDescription("Plays a single Brisa sound, replacing what is playing.")

    @Parameter(title: "Sound") var sound: SoundEntity

    static var parameterSummary: some ParameterSummary { Summary("Play \(\.$sound)") }

    @MainActor func perform() async throws -> some IntentResult & ProvidesDialog {
        let model = AppModel.shared
        guard let found = model.availableLibrary.first(where: { $0.id == sound.id }) else { throw BrisaIntentError.soundNotFound }
        model.replaceWith(found)
        return .result(dialog: "Playing \(found.name).")
    }
}

struct ResumeSoundsIntent: AppIntent {
    static let title: LocalizedStringResource = "Resume Sounds"
    static let description = IntentDescription("Plays the current Brisa mix again.")

    @MainActor func perform() async throws -> some IntentResult {
        let model = AppModel.shared
        if !model.isPlaying { model.togglePlayback() }
        return .result()
    }
}

struct PauseSoundsIntent: AppIntent {
    static let title: LocalizedStringResource = "Pause Sounds"
    static let description = IntentDescription("Pauses everything Brisa is playing.")

    @MainActor func perform() async throws -> some IntentResult {
        let model = AppModel.shared
        if model.isPlaying { model.togglePlayback() }
        return .result()
    }
}

struct SetVolumeIntent: AppIntent {
    static let title: LocalizedStringResource = "Set Brisa Volume"
    static let description = IntentDescription("Sets Brisa's master volume.")

    @Parameter(title: "Volume (%)", default: 50, inclusiveRange: (0, 100)) var percent: Int

    static var parameterSummary: some ParameterSummary { Summary("Set the volume to \(\.$percent)%") }

    @MainActor func perform() async throws -> some IntentResult {
        let model = AppModel.shared
        model.masterVolume = Double(min(max(percent, 0), 100)) / 100
        model.synchronizeAudio()
        return .result()
    }
}

struct SetSleepTimerIntent: AppIntent {
    static let title: LocalizedStringResource = "Stop Sounds After"
    static let description = IntentDescription("Starts Brisa's timer: sounds fade out and stop after the given minutes. Zero turns the timer off.")

    @Parameter(title: "Minutes", default: 30, inclusiveRange: (0, 600)) var minutes: Int

    static var parameterSummary: some ParameterSummary { Summary("Stop sounds after \(\.$minutes) minutes") }

    @MainActor func perform() async throws -> some IntentResult {
        let model = AppModel.shared
        model.remainingSeconds = max(0, minutes) * 60
        return .result()
    }
}

// MARK: - Modes

struct StartModeIntent: AppIntent {
    static let title: LocalizedStringResource = "Start Mode"
    static let description = IntentDescription("Opens a Brisa mode's apps, arranges their windows, and starts its sound and focus session.")

    @Parameter(title: "Mode") var mode: ModeEntity

    static var parameterSummary: some ParameterSummary { Summary("Start \(\.$mode)") }

    @MainActor func perform() async throws -> some IntentResult & ProvidesDialog {
        let model = AppModel.shared
        guard let saved = model.modes.first(where: { $0.id == mode.id }) else { throw BrisaIntentError.modeNotFound }
        model.startMode(saved)
        return .result(dialog: "\(saved.name) started.")
    }
}

struct EndModeIntent: AppIntent {
    static let title: LocalizedStringResource = "End Mode"
    static let description = IntentDescription("Ends the current Brisa mode: stops sounds and the focus timer and puts its apps away.")

    @MainActor func perform() async throws -> some IntentResult {
        AppModel.shared.endMode()
        return .result()
    }
}

// MARK: - Pomodoro

struct StartFocusSessionIntent: AppIntent {
    static let title: LocalizedStringResource = "Start Focus Session"
    static let description = IntentDescription("Starts a new Pomodoro focus session in Brisa.")

    @MainActor func perform() async throws -> some IntentResult & ProvidesDialog {
        let model = AppModel.shared
        model.resetPomodoro()
        model.startPomodoro()
        return .result(dialog: "Focus session started: \(model.workMinutes) minutes.")
    }
}

struct PauseFocusSessionIntent: AppIntent {
    static let title: LocalizedStringResource = "Pause Focus Session"
    static let description = IntentDescription("Pauses Brisa's Pomodoro timer.")

    @MainActor func perform() async throws -> some IntentResult {
        AppModel.shared.pausePomodoro()
        return .result()
    }
}

// MARK: - Focus filter

/// Set under System Settings → Focus → a Focus → Focus filters → Brisa.
/// The system runs it when that Focus turns on, and again with every option cleared when it turns off.
struct BrisaFocusFilter: SetFocusFilterIntent {
    static let title: LocalizedStringResource = "Set Brisa sounds"
    static let description = IntentDescription("Play a mix and start a focus session while this Focus is on. Brisa stops them when the Focus ends.")

    @Parameter(title: "Play mix") var mix: MixEntity?
    @Parameter(title: "Start a focus session", default: false) var startFocusSession: Bool

    var displayRepresentation: DisplayRepresentation {
        var parts: [String] = []
        if let mix { parts.append("Play \(mix.name)") }
        if startFocusSession { parts.append("start a focus session") }
        return DisplayRepresentation(title: parts.isEmpty ? "Brisa" : "\(parts.joined(separator: ", "))")
    }

    @MainActor func perform() async throws -> some IntentResult {
        let model = AppModel.shared
        let saved = mix.flatMap { entity in model.mixes.first { $0.id == entity.id } }
        model.applyFocusFilter(mix: saved, startFocusSession: startFocusSession)
        return .result()
    }
}

extension AppModel {
    /// Plays and starts what a Focus asks for, and when the Focus ends, stops only what the Focus started.
    func applyFocusFilter(mix: Mix?, startFocusSession: Bool) {
        let active = mix != nil || startFocusSession
        if active {
            if let mix {
                isAutomaticChange = true
                applyMix(mix)
                isAutomaticChange = false
                focusStartedSounds = true
            }
            if startFocusSession {
                resetPomodoro()
                startPomodoro()
                focusStartedSession = true
            }
            return
        }
        if focusStartedSounds, isPlaying { isPlaying = false; synchronizeAudio() }
        if focusStartedSession, isPomodoroRunning { pausePomodoro() }
        focusStartedSounds = false
        focusStartedSession = false
    }
}

// MARK: - Availability

enum BrisaIntegration {
    /// macOS only connects Shortcuts and Focus filters to apps signed by a developer team;
    /// ad-hoc builds ship without the actions, so the app doesn't mention them either.
    static let isAvailable: Bool = {
        var code: SecCode?
        var staticCode: SecStaticCode?
        var info: CFDictionary?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
              SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
              SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let details = info as? [String: Any] else { return false }
        return (details[kSecCodeInfoTeamIdentifier as String] as? String).map { !$0.isEmpty } ?? false
    }()

    static func refreshShortcutPhrases() {
        guard isAvailable else { return }
        BrisaShortcuts.updateAppShortcutParameters()
    }
}

// MARK: - Suggested phrases

struct BrisaShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: PlayMixIntent(), phrases: [
            "Play \(\.$mix) in \(.applicationName)",
            "Play my \(\.$mix) mix in \(.applicationName)"
        ], shortTitle: "Play Mix", systemImageName: "play.fill")
        AppShortcut(intent: PauseSoundsIntent(), phrases: [
            "Pause \(.applicationName)",
            "Pause sounds in \(.applicationName)"
        ], shortTitle: "Pause Sounds", systemImageName: "pause.fill")
        AppShortcut(intent: ResumeSoundsIntent(), phrases: [
            "Resume \(.applicationName)",
            "Resume sounds in \(.applicationName)"
        ], shortTitle: "Resume Sounds", systemImageName: "play.circle")
        AppShortcut(intent: StartModeIntent(), phrases: [
            "Start \(\.$mode) in \(.applicationName)",
            "Start my \(\.$mode) mode in \(.applicationName)"
        ], shortTitle: "Start Mode", systemImageName: "rectangle.3.group")
        AppShortcut(intent: StartFocusSessionIntent(), phrases: [
            "Start a focus session in \(.applicationName)",
            "Start focusing with \(.applicationName)"
        ], shortTitle: "Start Focus", systemImageName: "brain.head.profile")
    }
}
