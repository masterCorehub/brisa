# Source structure

## App and state

- `Main.swift` starts the app; `AppEntry.swift` owns the SwiftUI scenes (main window, menu bar), the desktop mini player, and the Settings sheet.
- `AppModel.swift` owns persisted user state: playback, mixes, favourites, the sleep timer and the Pomodoro timer. `Countdown` holds the two values that change every second, so a running timer only redraws the views that show it.
- `Theme.swift` defines the themes and the shared `BrisaThemeStore`.
- `SystemIntegration.swift` handles media keys, Now Playing, sleep and wake, and launch at login.
- `BrisaIntents.swift` provides Shortcuts, Siri and Spotlight actions and the Focus filter.

## Sound

- `SoundLibrary.swift` defines the built-in sounds and the saved-mix type.
- `AudioBank.swift` prepares sound loops off the main thread and plays the mix, with crossfades and the living mix.
- `SoundSynthesis.swift` generates the noise colours and binaural tones.
- `ImportedSounds.swift` and `ImportSoundsView.swift` import local files and audio links; `YouTubeVideos.swift` plays YouTube links in the embedded player.
- `MixSharing.swift` turns mixes into `.brisamix` files and `brisa://mix` links, and validates what comes in.
- `InputSounds.swift` and `InputSoundsView.swift` handle the optional keyboard and mouse sounds, including permissions.

## Focus

- `PomodoroTimerView.swift` is the Pomodoro page; `PomodoroWidget.swift` is the desktop Pomodoro widget; `Confetti.swift` is the end-of-phase celebration.
- `BreakActivities.swift` holds the break activities, what was done in each break, and the break screen settings (`BreakStore`). `BreakScreen.swift` shows the full-screen break screen between Pomodoro phases, and `BreakActivitiesView.swift` edits it from the Pomodoro page.
- `Routines.swift` and `RoutinesView.swift` schedule and edit routines.
- `Modes.swift` and `ModesView.swift` open apps, arrange their windows and quiet distractions.

## Other surfaces

- `ContentView.swift` (main window), `MenuBarPlayerView.swift`, `MixEditor.swift` and `WelcomeView.swift` each own one SwiftUI surface.

## Conventions

User actions that change playback, mixes, timers or preferences go through `AppModel` (or its extensions in `Routines.swift`, `Modes.swift` and `MixSharing.swift`). Features with their own settings keep them in a small shared store next to the feature, such as `BreakStore` and `BrisaThemeStore`. Services expose focused work only: `AudioBank` plays ambient layers and `InputSounds` handles keyboard and mouse feedback.

Pure logic (scheduling, sharing, synthesis, mode planning, break suggestions) lives in types without app state so `Tests/` can cover it.

The build script compiles every `Sources/*.swift` file. A new file also needs adding to `Brisa.xcodeproj` so Xcode builds match.
