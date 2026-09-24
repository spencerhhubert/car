import AppKit
import AVFoundation
import Observation
import CarKit
import SwiftUI

// Settings: a page of the window (the gear at the foot of the sidebar, or
// ⌘,), grouped sections like a pane of System Settings. What writes the
// words and keeps their time, and the key it needs; the microphones in the
// order to use them, the sound's quality and quick dictation's pause; the keys; what transcription has cost; what car keeps on
// the disk; the permissions; which build this is. A change is saved as it is
// made (config.json) and used from the next session or chunk on.
@MainActor @Observable
final class SettingsModel {
    private unowned let app: App

    var config = Config.load() {
        didSet {
            config.save()
            if config.keys != oldValue.keys { app.setKeys(on: config.keys) }
        }
    }
    private(set) var models: [OpenRouter.Model] = []
    private(set) var refreshing = false
    /// The microphones connected now.
    private(set) var connected: [AudioInputs.Device] = []
    private(set) var hasKey = false
    private(set) var keyError: String?
    private(set) var permissions = Permissions()
    private(set) var spending: [(name: String, total: Usage.Total)] = []
    private(set) var byModel: [(model: String, total: Usage.Total)] = []
    private(set) var disk: Storage.Use?

    struct Permissions: Equatable {
        var accessibility = false
        var microphone = false
        var screen = false
    }

    init(app: App) {
        self.app = app
        if let data = try? Data(contentsOf: Config.root.appending(path: "models.json")),
           let m = try? JSONDecoder().decode([OpenRouter.Model].self, from: data) { models = m }
    }

    /// Read again everything that can change outside this window: the
    /// microphones, the key, the grants, the spending, the disk. What asks
    /// the catalog or walks the disk runs off the main thread; until it
    /// comes back the page shows what it last knew, so nothing on it moves.
    func reload() {
        connected = AudioInputs.all()
        hasKey = Config.openRouterKey != nil
        permissions = Permissions(accessibility: Keys.trusted, microphone: Mic.permissionGranted,
                                  screen: Screenshot.hasPermission)
        Task {
            let (spans, models) = await Task.detached(priority: .userInitiated) {
                (Usage.spans.map { ($0.name, Usage.total(since: $0.since)) }, Usage.byModel(since: Usage.spans[2].since))
            }.value
            spending = spans
            byModel = models
            disk = await Task.detached(priority: .utility) { Storage.use() }.value
        }
    }

    /// The remote models to pick from: the fetched list, with the one in use
    /// kept in it.
    var remoteModels: [String] {
        let ids = models.map(\.id)
        return config.remoteModel.isEmpty || ids.contains(config.remoteModel) ? ids : [config.remoteModel] + ids
    }

    /// Connected microphones not on the list yet.
    var unlisted: [AudioInputs.Device] {
        connected.filter { d in !config.microphones.contains { $0.uid == d.uid } }
    }

    func isConnected(_ m: Config.Microphone) -> Bool { connected.contains { $0.uid == m.uid } }

    func list(_ d: AudioInputs.Device) { config.microphones.append(Config.Microphone(uid: d.uid, name: d.name)) }

    func unlist(_ m: Config.Microphone) { config.microphones.removeAll { $0.uid == m.uid } }

    /// Move a microphone up (-1) or down (+1) the list.
    func move(_ m: Config.Microphone, by step: Int) {
        guard let i = config.microphones.firstIndex(of: m), config.microphones.indices.contains(i + step) else { return }
        config.microphones.swapAt(i, i + step)
    }

    func saveKey(_ key: String) -> Bool {
        do {
            try Config.saveKey(key)
            keyError = nil
            reload()
            return true
        } catch {
            keyError = error.localizedDescription
            return false
        }
    }

    func refreshModels() {
        guard let key = Config.openRouterKey, !refreshing else { return }
        refreshing = true
        Task {
            defer { refreshing = false }
            do {
                models = try await OpenRouter.audioModels(key: key)
                try JSONEncoder().encode(models).write(to: Config.root.appending(path: "models.json"))
            } catch {
                Log.line("model list not refreshed: \(error.localizedDescription)")
            }
        }
    }

    func grantAccessibility() { Keys.requestTrust() }
    func grantMicrophone() { Task { _ = await Mic.requestPermission(); reload() } }
    func grantScreen() { Screenshot.requestPermission() }
    func grantAutomation() { Adapters.requestAutomation() }
}

struct SettingsView: View {
    @Bindable var model: SettingsModel
    @State private var changingKey = false
    @State private var key = ""

    var body: some View {
        Form {
            Section {
                Picker("Words by", selection: $model.config.remoteModel) {
                    Text("None: the on-device words").tag("")
                    Divider()
                    ForEach(model.remoteModels, id: \.self) { Text($0).tag($0) }
                }
                Picker("Times by", selection: $model.config.localModel) {
                    Text("Apple, on this Mac").tag("apple")
                    Text("None: spread over the voice").tag("none")
                }
                keyRow
            } header: {
                Text("Transcription")
            } footer: {
                HStack(alignment: .firstTextBaseline) {
                    Text("Only the voice is sent, a stretch at a time, to the model that writes the words. The on-device model keeps their time.")
                    Spacer()
                    Button(model.refreshing ? "Refreshing…" : "Refresh List") { model.refreshModels() }
                        .buttonStyle(.link)
                        .disabled(!model.hasKey || model.refreshing)
                }
                .textStyle(.note)
            }

            Section {
                ForEach(Array(model.config.microphones.enumerated()), id: \.element.id) { i, m in
                    microphoneRow(m, place: i + 1, last: i == model.config.microphones.count - 1)
                }
                LabeledContent {
                    Menu("Add Microphone") {
                        ForEach(model.unlisted, id: \.uid) { d in Button(d.name) { model.list(d) } }
                    }
                    .fixedSize()
                    .disabled(model.unlisted.isEmpty)
                } label: {
                    Text("\(model.config.microphones.count + 1). System default")
                    Text(model.config.microphones.isEmpty ? "whichever the Mac is set to" : "when none above is connected")
                        .textStyle(.detail)
                }
            } header: {
                Text("Microphones")
            } footer: {
                Text("car records from the first one here that is connected. It moves down the list when one is unplugged or sends no sound, and back up as soon as one higher up is plugged back in.")
                    .textStyle(.note)
            }

            Section {
                Picker("Quality", selection: $model.config.soundQuality) {
                    ForEach(SoundQuality.allCases, id: \.self) { Text($0.name).tag($0) }
                }
                LabeledContent("Quick dictation starts after") {
                    HStack(spacing: Spacing.s) {
                        Text("\(Int(model.config.dictationPause)) s of quiet").monospacedDigit()
                        Stepper("", value: $model.config.dictationPause, in: 5...120, step: 5).labelsHidden()
                    }
                }
            } header: {
                Text("Recording")
            } footer: {
                Text("\(model.config.soundQuality.name) quality: \(model.config.soundQuality.purpose). Transcription hears the same at any quality. A change is used from the next session.")
                    .textStyle(.note)
            }

            Section {
                Toggle("Use these keys", isOn: $model.config.keys)
                LabeledContent("⌘ ⌥ ⌥", value: "start or stop a session")
                LabeledContent("⌥ ⌥", value: "set a marker for an agent")
                LabeledContent("⇧ ⌥ ⌥", value: "copy what you just said")
            } header: {
                Text("Keys")
            } footer: {
                Text("Hold ⌘ or ⇧, or neither, and tap ⌥ twice.\(Config.isDev ? " The development copy starts with its keys off, since both copies see every tap." : "")")
                    .textStyle(.note)
            }

            Section("Spent on transcription") {
                ForEach(model.spending, id: \.name) { s in
                    LabeledContent(s.name.prefix(1).uppercased() + s.name.dropFirst(),
                                   value: "\(Usage.dollars(s.total.cost)) · \(Int(s.total.audioSeconds / 60)) min of voice")
                }
                ForEach(model.byModel, id: \.model) { m in
                    LabeledContent(m.model, value: "\(Usage.dollars(m.total.cost)) in 30 days").textStyle(.detail)
                }
            }

            Section {
                permission("Accessibility", "keys, and what is in front", model.permissions.accessibility,
                           model.grantAccessibility)
                permission("Microphone", "your voice", model.permissions.microphone, model.grantMicrophone)
                permission("Screen Recording", "pictures, and fading drawings", model.permissions.screen,
                           model.grantScreen)
                LabeledContent {
                    Button("Ask") { model.grantAutomation() }
                } label: {
                    Text("Automation")
                    Text("Finder's selection and a browser's page").textStyle(.detail)
                }
            } header: {
                Text("Permissions")
            } footer: {
                Text("Each is given once, in System Settings.").textStyle(.note)
            }

            Section {
                let d = model.disk
                LabeledContent("Pictures", value: d.map { Storage.bytes($0.pictures) } ?? "…")
                LabeledContent("Sound", value: d.map { Storage.bytes($0.sound) } ?? "…")
                LabeledContent("Catalog", value: d.map { Storage.bytes($0.catalog + $0.other) } ?? "…")
                LabeledContent("All of it", value: d.map { Storage.bytes($0.total) } ?? "…").fontWeight(.medium)
                LabeledContent("Free on this disk", value: d?.free.map(Storage.bytes) ?? "…")
            } header: {
                Text("Disk")
            } footer: {
                HStack(alignment: .firstTextBaseline) {
                    Text("Sessions are kept in \(Config.sessionsDir.path).")
                    Spacer()
                    Button("Show in Finder") {
                        try? FileManager.default.createDirectory(at: Config.sessionsDir, withIntermediateDirectories: true)
                        NSWorkspace.shared.open(Config.sessionsDir)
                    }
                    .buttonStyle(.link)
                }
                .textStyle(.note)
            }

            Section("About") {
                LabeledContent("Version", value: "\(Config.name) \(Config.version)")
                LabeledContent("Log") {
                    Button("Open") {
                        NSWorkspace.shared.open(FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
                            .appending(path: "Logs/\(Config.name).log"))
                    }
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .frame(maxWidth: Metrics.settingsWidth)
        .frame(maxWidth: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.reload()
        }
    }

    @ViewBuilder
    private var keyRow: some View {
        if changingKey || !model.hasKey {
            LabeledContent("OpenRouter key") {
                HStack {
                    SecureField("", text: $key, prompt: Text("sk-or-…"))
                        .labelsHidden()
                        .frame(minWidth: 220)
                        .onSubmit(saveKey)
                    Button("Save", action: saveKey).disabled(key.isEmpty)
                    if model.hasKey { Button("Cancel") { changingKey = false; key = "" } }
                }
            }
            if let e = model.keyError { Text(e).textStyle(.note).foregroundStyle(Tint.failed) }
        } else {
            LabeledContent("OpenRouter key") {
                HStack {
                    Text("Saved").foregroundStyle(.secondary)
                    Button("Change…") { changingKey = true }
                }
            }
        }
    }

    private func saveKey() {
        if model.saveKey(key) {
            key = ""
            changingKey = false
        }
    }

    private func microphoneRow(_ m: Config.Microphone, place: Int, last: Bool) -> some View {
        LabeledContent {
            HStack(spacing: Spacing.xs) {
                Button { model.move(m, by: -1) } label: { Image(systemName: "chevron.up") }
                    .disabled(place == 1)
                    .help("Use it before the one above")
                Button { model.move(m, by: 1) } label: { Image(systemName: "chevron.down") }
                    .disabled(last)
                    .help("Use it after the one below")
                Button { model.unlist(m) } label: { Image(systemName: "minus.circle") }
                    .help("Take it off the list")
            }
            .buttonStyle(.borderless)
        } label: {
            Text("\(place). \(m.name)")
            Text(model.isConnected(m) ? "connected" : "not connected").textStyle(.detail)
        }
    }

    private func permission(_ name: String, _ why: String, _ granted: Bool, _ grant: @escaping () -> Void) -> some View {
        LabeledContent {
            if granted {
                Label("Granted", systemImage: "checkmark").labelStyle(.titleAndIcon).foregroundStyle(.secondary)
            } else {
                Button("Grant…", action: grant)
            }
        } label: {
            Text(name)
            Text(why).textStyle(.detail)
        }
    }
}
