import AppKit
import CarKit
import SwiftUI

// The sessions window's sidebar: every session by day, newest first, each
// with the first words said in it, the way Mail and Notes list theirs.
struct SessionList: View {
    @Bindable var library: Library

    var body: some View {
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
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([Session.dir(id)]) }
            }
        }
        .overlay {
            if library.loaded, library.sessions.isEmpty {
                ContentUnavailableView("No Sessions", systemImage: "waveform",
                                       description: Text("Hold ⌘ and tap ⌥ twice to start one."))
            }
        }
        .task { await library.follow() }
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
