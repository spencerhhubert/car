import AppKit
import CarKit
import SwiftUI

// The window's sidebar: every session by day, newest first, each with the
// first words said in it, the way Mail and Notes list theirs; and at its
// foot, Settings.
struct Sidebar: View {
    @Bindable var library: Library

    var body: some View {
        // The list, and beneath it (never over it) Settings.
        VStack(spacing: 0) {
            list
            settings
        }
        .task { await library.follow() }
    }

    private var list: some View {
        List(selection: $library.selectedID) {
            ForEach(library.days, id: \.day) { day in
                Section(day.day) {
                    ForEach(day.sessions) { SessionRow(session: $0) }
                }
            }
        }
        .listStyle(.sidebar)
        .contextMenu(forSelectionType: String.self) { ids in
            if let id = ids.first {
                Button("Copy for Agent") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(Pointer.session(id), forType: .string)
                }
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting(Session.folders(id)) }
            }
        }
        .overlay {
            if library.loaded, library.sessions.isEmpty {
                Text("No sessions yet").textStyle(.note)
            }
        }
    }

    private var settings: some View {
        let on = library.page == .settings
        return HStack {
            Button { library.page = .settings } label: {
                Label("Settings", systemImage: on ? "gearshape.fill" : "gearshape")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(on ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
            .help("Settings (⌘,)")
            Spacer()
        }
        .padding(.horizontal, Spacing.l)
        .padding(.vertical, Spacing.m)
    }
}

private struct SessionRow: View {
    let session: SessionSummary

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xxs) {
            HStack(spacing: Spacing.xs) {
                Text(session.record.started.map(Format.time) ?? session.id).textStyle(.listTitle)
                Spacer(minLength: Spacing.s)
                trailing
            }
            Text(opening)
                .textStyle(.listDetail)
                .lineLimit(2)
        }
        .padding(.vertical, Spacing.xxs)
    }

    private var opening: String {
        if !session.opening.isEmpty { return session.opening }
        switch session.record.state {
        case .recording, .transcribing: return "Words to come"
        case .done, .failed: return "Nothing was said"
        }
    }

    @ViewBuilder
    private var trailing: some View {
        switch session.record.state {
        case .recording:
            HStack(spacing: Spacing.xs) {
                RecordingDot()
                if let started = session.record.started {
                    TimelineView(.periodic(from: .now, by: 1)) { t in
                        Text(Format.length(ms: Int(t.date.timeIntervalSince(started) * 1000))).textStyle(.time)
                    }
                }
            }
        case .transcribing:
            ProgressView().controlSize(.mini).help("Transcribing the last of it")
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Tint.failed)
                .help(session.record.error ?? "Some of it could not be transcribed")
        case .done:
            Text(Format.length(ms: session.record.lengthMs ?? 0)).textStyle(.time)
        }
    }
}
