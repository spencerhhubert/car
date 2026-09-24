import AppKit
import CarKit
import SwiftUI

// A session as a script: a title, then one row per moment down a long
// scroll, each in three columns: what was said, with the time it was said in
// the margin; what was done around it; the pictures taken then. A marker is
// a line across; a long stretch of nothing says how long. Where the words are
// still to come the row says so, and a session being recorded grows at the
// bottom as it goes, the view following it there unless scrolled away.
// Clicking a picture shows it big (PictureViewer.swift).

/// The sessions window's main pane: the session picked in the sidebar.
struct ScriptPane: View {
    let library: Library
    let model: ScriptModel

    var body: some View {
        if let id = library.selectedID {
            ScriptView(model: model)
                .task(id: id) { await model.follow(id) }
        } else if library.loaded {
            ContentUnavailableView("No Session", systemImage: "waveform",
                                   description: Text("Hold ⌘ and tap ⌥ twice to start one."))
        }
    }
}

private struct ScriptView: View {
    @Bindable var model: ScriptModel
    @State private var width: CGFloat = 0
    @State private var position = ScrollPosition(edge: .top)
    @State private var atBottom = false

    var body: some View {
        if let s = model.script {
            let columns = Columns(width: width)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    Header(script: s)
                    ForEach(s.rows) { row in
                        RowView(row: row, id: s.id, time: time(row.start, in: s), columns: columns,
                                open: { model.viewing = $0 })
                            .equatable()
                    }
                    Footer(script: s)
                }
                .padding(.horizontal, Metrics.scriptMargin)
            }
            .scrollPosition($position)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
            .onScrollGeometryChange(for: Bool.self) { g in
                g.contentOffset.y + g.containerSize.height >= g.contentSize.height - 80
            } action: { _, bottom in
                atBottom = bottom
            }
            // A live session opens at its newest and follows it while the
            // view is left there; a finished one opens at its start.
            .onChange(of: s.id, initial: true) {
                position.scrollTo(edge: s.status == .recording ? .bottom : .top)
            }
            .onChange(of: s.length) {
                if s.status == .recording, atBottom { position.scrollTo(edge: .bottom) }
            }
            .overlay {
                if model.viewing != nil { PictureViewer(script: s, viewing: $model.viewing) }
            }
        } else if model.missing {
            ContentUnavailableView("No Such Session", systemImage: "questionmark.folder",
                                   description: Text("It was discarded or removed."))
        } else {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func time(_ t: Int, in s: Script) -> String {
        s.date(t).map(Format.timeSeconds) ?? Render.clock(t)
    }
}

/// The widths of the script's columns, from the width of the pane: the words
/// take what the others leave.
private struct Columns: Equatable {
    let gutter = Metrics.scriptGutter
    let actions: CGFloat
    let pictures: CGFloat

    init(width: CGFloat) {
        let content = max(0, width - 2 * Metrics.scriptMargin)
        actions = min(300, max(180, content * 0.26))
        pictures = min(200, max(140, content * 0.19))
    }
}

private struct Header: View {
    let script: Script

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            HStack(alignment: .firstTextBaseline, spacing: Spacing.m) {
                Text(script.started.map(Format.session) ?? script.id).textStyle(.title)
                StatusBadge(status: script.status)
            }
            if script.status == .recording, let started = script.started {
                TimelineView(.periodic(from: .now, by: 1)) { t in
                    Text(facts(length: Int(t.date.timeIntervalSince(started) * 1000))).textStyle(.subtitle)
                }
            } else {
                Text(facts(length: script.length)).textStyle(.subtitle)
            }
        }
        .padding(.top, Spacing.l)
        .padding(.bottom, Spacing.xl)
    }

    private func facts(length: Int) -> String {
        var f = [Format.length(ms: length), Format.count(script.words, "word"), Format.count(script.pictures.count, "picture")]
        if script.markers > 0 { f.append(Format.count(script.markers, "marker")) }
        if script.cost > 0 { f.append(Usage.dollars(script.cost)) }
        return f.joined(separator: " · ")
    }
}

private struct Footer: View {
    let script: Script

    var body: some View {
        HStack(spacing: Spacing.s) {
            switch script.status {
            case .recording:
                RecordingDot()
                Text("Recording. Words come in every few minutes, and at once when you set a marker (⌥ ⌥).")
            case .transcribing:
                ProgressView().controlSize(.mini)
                Text("Transcribing the last of it.")
            case .failed(let why):
                Image(systemName: "exclamationmark.triangle.fill").symbolRenderingMode(.multicolor)
                Text("Some of it could not be transcribed: \(why)")
            case .done:
                Text(script.date(script.length).map { "Ended \(Format.timeSeconds($0))" } ?? "Ended")
            }
        }
        .textStyle(.note)
        .padding(.leading, Metrics.scriptGutter + Metrics.columnSpacing)
        .padding(.vertical, Spacing.xl)
    }
}

private struct RowView: View, Equatable {
    let row: Script.Row
    let id: String
    let time: String
    let columns: Columns
    let open: (Int) -> Void

    nonisolated static func == (a: RowView, b: RowView) -> Bool {
        a.row == b.row && a.time == b.time && a.columns == b.columns
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let gap = row.gapBefore {
                Text("\(Format.span(ms: gap)) later")
                    .textStyle(.note)
                    .padding(.leading, columns.gutter + Metrics.columnSpacing)
                    .padding(.vertical, Spacing.m)
            }
            if let m = row.marker {
                MarkerLine(marker: m, id: id, time: time, gutter: columns.gutter)
            } else {
                HStack(alignment: .firstTextBaseline, spacing: Metrics.columnSpacing) {
                    Text(time)
                        .textStyle(.time)
                        .frame(width: columns.gutter, alignment: .leading)
                        .help("\(Render.clock(row.start)) into the session")
                    SpeechCell(speech: row.speech)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    ActionsCell(actions: row.actions)
                        .frame(width: columns.actions, alignment: .leading)
                    PicturesCell(pictures: row.pictures, width: columns.pictures, open: open)
                        .frame(width: columns.pictures, alignment: .leading)
                }
                .padding(.vertical, Spacing.s + Spacing.xxs)
            }
        }
    }
}

private struct SpeechCell: View {
    let speech: Script.Row.Speech

    var body: some View {
        switch speech {
        case .said(let text):
            Text(Said.styled(text))
                .textStyle(.speech)
                .lineSpacing(Spacing.xxs)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        case .quiet:
            Color.clear.frame(height: 1)
        case .recording(let first):
            Pending(label: first ? "Words to come" : nil, recording: true)
        case .transcribing(let first):
            Pending(label: first ? "Transcribing" : nil, recording: false)
        case .failed(let why, let first):
            if first {
                VStack(alignment: .leading, spacing: Spacing.xxs) {
                    Label("Not transcribed", systemImage: "exclamationmark.triangle.fill")
                        .symbolRenderingMode(.multicolor)
                        .textStyle(.action)
                    Text(why).textStyle(.note)
                }
            } else {
                Color.clear.frame(height: 1)
            }
        case .lost(let first):
            if first {
                Text("Not saved: car stopped before this stretch was written.").textStyle(.note)
            } else {
                Color.clear.frame(height: 1)
            }
        }
    }
}

private struct ActionsCell: View {
    let actions: [Script.Action]
    @State private var expanded = false
    private static let shown = 6

    var body: some View {
        let hidden = expanded ? 0 : max(0, actions.count - Self.shown)
        VStack(alignment: .leading, spacing: Spacing.xs) {
            if actions.isEmpty { Color.clear.frame(height: 1) }
            ForEach(actions.prefix(actions.count - hidden)) { ActionLine(action: $0) }
            if hidden > 0 {
                Button("\(hidden) more") { expanded = true }
                    .buttonStyle(.link)
                    .textStyle(.detail)
                    .padding(.leading, Metrics.actionSymbol + Spacing.s)
            }
        }
    }
}

private struct ActionLine: View {
    let action: Script.Action

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.s) {
            Image(systemName: action.kind.symbol)
                .font(TextStyle.note.font)
                .foregroundStyle(action.ink.map { AnyShapeStyle(Tint.ink($0)) } ?? AnyShapeStyle(.tertiary))
                .frame(width: Metrics.actionSymbol)
            Text("\(Text(action.text).foregroundStyle(.secondary))\(Text(action.detail.map { "  \($0)" } ?? "").foregroundStyle(.tertiary))")
                .font(TextStyle.action.font)
                .lineLimit(1)
                .truncationMode(.tail)
            if action.count > 1 {
                Text("×\(action.count)").textStyle(.detail)
            }
        }
        .help([action.text, action.detail].compactMap { $0 }.joined(separator: " · "))
    }
}

private struct PicturesCell: View {
    let pictures: [Script.Picture]
    let width: CGFloat
    let open: (Int) -> Void

    var body: some View {
        // Always the column's width, pictures or not, so the columns of
        // every row line up.
        if pictures.isEmpty {
            Color.clear.frame(width: width, height: 1)
        } else if let first = pictures.first {
            let rest = pictures.dropFirst()
            let room = max(1, Int((width + Spacing.xs) / (Metrics.smallPicture.width + Spacing.xs)))
            let small = rest.count > room ? room - 1 : rest.count
            VStack(alignment: .leading, spacing: Spacing.xs) {
                picture(first, CGSize(width: width, height: (width * Metrics.pictureAspect).rounded()))
                if !rest.isEmpty {
                    HStack(spacing: Spacing.xs) {
                        ForEach(rest.prefix(small)) { picture($0, Metrics.smallPicture) }
                        if rest.count > small {
                            Button { open(rest[rest.startIndex + small].id) } label: {
                                Text("+\(rest.count - small)")
                                    .textStyle(.note)
                                    .frame(width: Metrics.smallPicture.width, height: Metrics.smallPicture.height)
                                    .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: Radius.medium))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .alignmentGuide(.firstTextBaseline) { $0[.top] + Metrics.firstLine }
        }
    }

    private func picture(_ p: Script.Picture, _ size: CGSize) -> some View {
        Button { open(p.id) } label: { Thumbnail(url: p.url, size: size) }
            .buttonStyle(.plain)
            .help(p.reason)
    }
}

private struct MarkerLine: View {
    let marker: Script.Marker
    let id: String
    let time: String
    let gutter: CGFloat
    @State private var copied = false

    var body: some View {
        HStack(alignment: .center, spacing: Metrics.columnSpacing) {
            Text(time).textStyle(.time).frame(width: gutter, alignment: .leading)
            HStack(spacing: Spacing.s) {
                Image(systemName: "flag.fill").font(TextStyle.note.font).foregroundStyle(.secondary)
                Text("Marker \(marker.n)").font(TextStyle.action.font.weight(.semibold))
                Rectangle().fill(.separator).frame(height: 1)
                Button {
                    guard let at = marker.at else { return }
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(Pointer.marker(marker.n, at: at, in: id), forType: .string)
                    copied = true
                } label: {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                }
                .buttonStyle(.borderless)
                .help("Copy the line that hands this marker to an agent")
                .task(id: copied) {
                    guard copied else { return }
                    try? await Task.sleep(for: .seconds(1.5))
                    copied = false
                }
            }
        }
        .padding(.vertical, Spacing.m)
    }
}

extension Metrics {
    static let actionSymbol: CGFloat = 14
}
