import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Pomodoro sidebar card: when the break screen appears and what it offers to do.
struct BreakScreenCard: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var store = BreakStore.shared
    @ObservedObject private var themeStore = BrisaThemeStore.shared
    @State private var expanded = false
    @State private var editing: BreakActivity?
    @State private var confirmRestore = false

    private var tint: Color { themeStore.current.color(for: .shortBreak) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Break screen").font(.caption.weight(.bold)).tracking(1.2).textCase(.uppercase).foregroundStyle(.secondary)
                Spacer()
                Button { withAnimation(.easeInOut(duration: 0.2)) { expanded.toggle() } } label: {
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                }
                .buttonStyle(.plain).foregroundStyle(.secondary)
                .accessibilityLabel(expanded ? "Hide break screen settings" : "Show break screen settings")
            }
            if expanded { details } else { summary }
        }
        .padding(18).frame(maxWidth: .infinity, alignment: .leading)
        .background(surface.opacity(0.04), in: RoundedRectangle(cornerRadius: 18))
        .sheet(item: $editing) { activity in
            BreakActivityEditor(activity: activity, isNew: !store.activities.contains { $0.id == activity.id }) { store.upsert($0) }
        }
        .confirmationDialog("Restore the suggested activities?", isPresented: $confirmRestore) {
            Button("Restore", role: .destructive) { withAnimation { store.restoreDefaults() } }
        } message: {
            Text("Your own activities and changes are replaced by Brisa's suggestions.")
        }
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(store.showAfterFocus
                 ? "Full screen when focus ends · \(store.activities.filter(\.isEnabled).count) activities"
                 : "Off · you get a notification instead")
                .font(.callout).foregroundStyle(.secondary)
            todayLine
        }
    }

    @ViewBuilder private var todayLine: some View {
        let today = store.today
        if !today.isEmpty {
            Text("Today: " + today.prefix(4).map { $0.count > 1 ? "\($0.title) ×\($0.count)" : $0.title }.joined(separator: " · "))
                .font(.caption).foregroundStyle(.secondary).lineLimit(2)
        }
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle("Full-screen break screen when focus ends", isOn: $store.showAfterFocus)
            Toggle("Also when a break ends", isOn: $store.showAfterBreak)
            Toggle("Keep it open during the break", isOn: $store.staysOpen)
            Text("Shows what you picked and the countdown until the break is over. Activities that open an app or a link always close it.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Toggle("Dim other displays", isOn: $store.dimOtherDisplays)
            HStack {
                Button { BreakScreen.shared.preview(.breakStarting) } label: { Label("Preview", systemImage: "eye") }
                Button { BreakScreen.shared.preview(.backToFocus(.shortBreak)) } label: { Text("End of break") }
                    .help("Preview the screen shown when a break ends")
            }
            .controlSize(.small)

            Divider().opacity(0.4)
            HStack {
                Text("Activities").font(.headline)
                Spacer()
                Button { editing = BreakActivity(title: "", symbol: "sparkles") } label: { Label("Add", systemImage: "plus") }
                    .controlSize(.small)
            }
            Text("Offered on the break screen. The one you did least recently is suggested first.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            VStack(spacing: 6) {
                ForEach(store.activities) { row($0) }
            }
            HStack {
                Button("Restore suggestions") { confirmRestore = true }
                Spacer()
                if !store.log.isEmpty { Button("Clear history") { store.clearLog() } }
            }
            .buttonStyle(.plain).font(.caption).foregroundStyle(.secondary)
            todayLine
        }
        .font(.callout)
    }

    private func row(_ activity: BreakActivity) -> some View {
        let target = BreakActivities.target(activity.opens)
        var meta = [activity.fit.title]
        if let minutes = activity.minutes { meta.append("\(minutes) min") }
        if let target { meta.append("opens \(BreakActivities.targetName(target))") }
        return HStack(spacing: 10) {
            Toggle("", isOn: Binding(get: { activity.isEnabled }, set: { store.setEnabled(activity.id, $0) }))
                .toggleStyle(.checkbox).labelsHidden()
                .accessibilityLabel("Offer \(activity.title)")
            Image(systemName: activity.symbol).frame(width: 22).foregroundStyle(activity.isEnabled ? tint : .secondary)
            Button { editing = activity } label: {
                VStack(alignment: .leading, spacing: 1) {
                    Text(activity.title).lineLimit(1).foregroundStyle(activity.isEnabled ? .primary : .secondary)
                    Text(meta.joined(separator: " · ")).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            }
            .buttonStyle(.plain).help("Edit")
            Button { withAnimation { store.remove(activity.id) } } label: { Image(systemName: "xmark").font(.caption) }
                .buttonStyle(.plain).foregroundStyle(.tertiary).accessibilityLabel("Delete \(activity.title)")
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(surface.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
        .contextMenu {
            Button { editing = activity } label: { Label("Edit", systemImage: "pencil") }
            Button { withAnimation { store.move(activity.id, by: -1) } } label: { Label("Move up", systemImage: "arrow.up") }
            Button { withAnimation { store.move(activity.id, by: 1) } } label: { Label("Move down", systemImage: "arrow.down") }
            Divider()
            Button(role: .destructive) { withAnimation { store.remove(activity.id) } } label: { Label("Delete", systemImage: "trash") }
        }
    }
}

/// Creates or edits one break activity.
struct BreakActivityEditor: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var themeStore = BrisaThemeStore.shared
    @State private var draft: BreakActivity
    @State private var setsLength: Bool
    let isNew: Bool
    let onSave: (BreakActivity) -> Void

    init(activity: BreakActivity, isNew: Bool, onSave: @escaping (BreakActivity) -> Void) {
        _draft = State(initialValue: activity)
        _setsLength = State(initialValue: activity.minutes != nil)
        self.isNew = isNew
        self.onSave = onSave
    }

    private var opensIsValid: Bool { draft.opens.trimmingCharacters(in: .whitespaces).isEmpty || BreakActivities.target(draft.opens) != nil }
    private var canSave: Bool { !draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && opensIsValid }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(isNew ? "New break activity" : "Edit break activity").font(.title2.weight(.semibold))
            VStack(alignment: .leading, spacing: 8) {
                TextField("Name, e.g. Drink water", text: $draft.title).textFieldStyle(.roundedBorder)
                TextField("Hint (optional), e.g. A full glass", text: $draft.note).textFieldStyle(.roundedBorder)
            }

            Text("Icon").font(.headline)
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(36), spacing: 8), count: 10), spacing: 8) {
                ForEach(BreakActivities.symbols, id: \.self) { symbol in
                    let selected = draft.symbol == symbol
                    Button { draft.symbol = symbol } label: {
                        Image(systemName: symbol).font(.system(size: 15)).frame(width: 36, height: 36)
                            .background(selected ? accent.opacity(0.3) : surface.opacity(0.06), in: RoundedRectangle(cornerRadius: 9))
                            .overlay(RoundedRectangle(cornerRadius: 9).stroke(selected ? accent : .clear, lineWidth: 1.5))
                    }
                    .buttonStyle(.plain).accessibilityLabel(symbol).accessibilityAddTraits(selected ? .isSelected : [])
                }
            }

            Picker("Offer in", selection: $draft.fit) {
                ForEach(BreakActivity.Fit.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)

            VStack(alignment: .leading, spacing: 6) {
                Toggle("Change the break length", isOn: $setsLength)
                if setsLength {
                    Stepper("\(draft.minutes ?? 10) minutes", value: Binding(get: { draft.minutes ?? 10 }, set: { draft.minutes = $0 }), in: 1...60)
                }
                Text("Picking this activity sets the current break to this length, for example a longer break for a walk.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Open when picked (optional)").font(.headline)
                HStack {
                    TextField("A link, e.g. https://lichess.org", text: $draft.opens).textFieldStyle(.roundedBorder)
                    Button("Choose app…", action: chooseApp)
                }
                if !opensIsValid {
                    Text("Enter a web link, an app link, or choose an app.").font(.caption).foregroundStyle(.orange)
                } else {
                    Text("A game, a playlist, a meditation app… The break screen closes so you can use it.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            Toggle("Offer this activity", isOn: $draft.isEnabled)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(isNew ? "Add" : "Save", action: save).keyboardShortcut(.defaultAction).disabled(!canSave)
            }
        }
        .padding(26).frame(width: 520)
        .tint(accent).preferredColorScheme(themeStore.current.scheme)
    }

    private func chooseApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.applicationBundle]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = "Choose"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        draft.opens = url.path
        if draft.title.trimmingCharacters(in: .whitespaces).isEmpty { draft.title = url.deletingPathExtension().lastPathComponent }
    }

    private func save() {
        draft.title = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
        draft.note = draft.note.trimmingCharacters(in: .whitespacesAndNewlines)
        draft.opens = draft.opens.trimmingCharacters(in: .whitespacesAndNewlines)
        draft.minutes = setsLength ? (draft.minutes ?? 10) : nil
        onSave(draft)
        dismiss()
    }
}
