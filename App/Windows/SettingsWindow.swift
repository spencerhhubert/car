import AppKit
import AVFoundation
import Observation
import CarKit
import SwiftUI

// Settings: one page of grouped sections, like a pane of System Settings.
// What writes the words and keeps their time, and the key it needs; the
// microphone and quick dictation's pause; the keys; what transcription has
// cost; the permissions; which build this is. A change is saved as it is
// made (config.json) and used from the next session or chunk on.
@MainActor
final class SettingsWindow: NSWindowController {
    init(app: App) {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: Metrics.settingsWindow),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = "Settings"
        window.contentViewController = host(SettingsView(model: SettingsModel(app: app)))
        window.setContentSize(Metrics.settingsWindow)
        window.center()
        super.init(window: window)
    }

    required init?(coder: NSCoder) { fatalError("not from a nib") }
}

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
    private(set) var inputs: [AudioInputs.Device] = []
    private(set) var hasKey = false
    private(set) var keyError: String?
    private(set) var permissions = Permissions()
    private(set) var spending: [(name: String, total: Usage.Total)] = []
    private(set) var byModel: [(model: String, total: Usage.Total)] = []

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
    /// microphones, the key, the grants, the spending.
    func reload() {
        inputs = AudioInputs.all()
        hasKey = Config.openRouterKey != nil
        permissions = Permissions(accessibility: Keys.trusted, microphone: Mic.permissionGranted,
                                  screen: Screenshot.hasPermission)
        spending = Usage.spans.map { ($0.name, Usage.total(since: $0.since)) }
        byModel = Usage.byModel(since: Usage.spans[2].since)
    }

    /// The remote models to pick from: the fetched list, with the one in use
    /// kept in it.
    var remoteModels: [String] {
        let ids = models.map(\.id)
        return config.remoteModel.isEmpty || ids.contains(config.remoteModel) ? ids : [config.remoteModel] + ids
    }

    var input: String? {
        get { config.inputUID }
        set {
            config.inputUID = newValue
            config.inputName = newValue.flatMap { uid in inputs.first { $0.uid == uid }?.name }
        }
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

private struct SettingsView: View {
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

            Section("Recording") {
                Picker("Microphone", selection: $model.input) {
                    Text("System Default").tag(String?.none)
                    ForEach(model.inputs, id: \.uid) { Text($0.name).tag(String?.some($0.uid)) }
                }
                LabeledContent("Quick dictation starts after") {
                    HStack(spacing: Spacing.s) {
                        Text("\(Int(model.config.dictationPause)) s of quiet").monospacedDigit()
                        Stepper("", value: $model.config.dictationPause, in: 5...120, step: 5).labelsHidden()
                    }
                }
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

            Section("About") {
                LabeledContent("Version", value: "\(Config.name) \(Config.version)")
                LabeledContent("Sessions") {
                    Button("Show in Finder") {
                        try? FileManager.default.createDirectory(at: Config.sessionsDir, withIntermediateDirectories: true)
                        NSWorkspace.shared.open(Config.sessionsDir)
                    }
                }
                LabeledContent("Log") {
                    Button("Open") {
                        NSWorkspace.shared.open(FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
                            .appending(path: "Logs/\(Config.name).log"))
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { model.reload() }
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
