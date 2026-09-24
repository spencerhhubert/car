import AppKit
import CarKit
import SwiftUI

// What each line of the script draws: the title and facts, a row, or the
// end. A row is three columns: what was said (its time in the margin), what
// was done around it, and the pictures taken then. A marker is a line across;
// a long stretch of nothing says how long; where words are still to come the
// row holds their place.
//
// These views only draw. The table (ScriptController.swift) gives each line
// its height from ScriptLayout, and the views lay out top-down inside it,
// every column at a width the layout fixed: no alignment guides, no state
// that changes a size, nothing that asks the table for room.

/// A line of the script's table.
enum ScriptLine: Identifiable, Equatable {
    case header
    case row(Script.Row)
    case footer

    var id: String {
        switch self {
        case .header: "header"
        case .row(let r): r.id
        case .footer: "footer"
        }
    }
}

struct LineView: View {
    let line: ScriptLine
    let script: Script
    let layout: ScriptLayout
    var expanded = false
    var open: (Int) -> Void = { _ in }
    var expand: () -> Void = {}

    var body: some View {
        Group {
            switch line {
            case .header:
                Header(script: script)
            case .row(let row):
                RowView(row: row, id: script.id, time: script.date(row.start).map(Format.timeSeconds) ?? Render.clock(row.start),
                        layout: layout, expanded: expanded, open: open, expand: expand)
            case .footer:
                Footer(script: script)
            }
        }
        .padding(.horizontal, Metrics.scriptMargin)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

private struct Header: View {
    let script: Script

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            HStack(alignment: .firstTextBaseline, spacing: Spacing.m) {
                Text(script.started.map(Format.session) ?? script.id).textStyle(.title).lineLimit(1)
                StatusBadge(status: script.status)
            }
            if script.status == .recording, let started = script.started {
                TimelineView(.periodic(from: .now, by: 1)) { t in
                    Text(facts(length: Int(t.date.timeIntervalSince(started) * 1000))).textStyle(.subtitle).lineLimit(1)
                }
            } else {
                Text(facts(length: script.length)).textStyle(.subtitle).lineLimit(1)
            }
        }
        .padding(.top, Spacing.l)
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
        HStack(alignment: .top, spacing: Spacing.s) {
            switch script.status {
            case .recording:
                RecordingDot().padding(.top, 3)
            case .transcribing:
                ProgressView().controlSize(.mini)
            case .failed:
                Image(systemName: "exclamationmark.triangle.fill").symbolRenderingMode(.multicolor)
            case .done:
                EmptyView()
            }
            Text(Footer.note(script)).fixedSize(horizontal: false, vertical: true)
        }
        .textStyle(.note)
        .padding(.leading, Metrics.scriptGutter + Metrics.columnSpacing)
        .padding(.vertical, Spacing.xl)
    }

    /// What the footer says, which ScriptLayout measures too.
    static func note(_ script: Script) -> String {
        switch script.status {
        case .recording: "Recording. Words come in every few minutes, and at once when you set a marker (⌥ ⌥)."
        case .transcribing: "Transcribing the last of it."
        case .failed(let why): "Some of it could not be transcribed: \(why)"
        case .done: script.date(script.length).map { "Ended \(Format.timeSeconds($0))" } ?? "Ended"
        }
    }
}

extension ScriptLine {
    /// Its height in `layout`.
    func height(in layout: ScriptLayout, script: Script, expanded: Bool) -> CGFloat {
        switch self {
        case .header: layout.headerHeight
        case .row(let r): layout.height(r, expanded: expanded)
        case .footer: layout.footerHeight(Footer.note(script))
        }
    }
}

private struct RowView: View {
    let row: Script.Row
    let id: String
    let time: String
    let layout: ScriptLayout
    let expanded: Bool
    let open: (Int) -> Void
    let expand: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let gap = row.gapBefore {
                Text("\(Format.span(ms: gap)) later")
                    .textStyle(.note)
                    .padding(.leading, layout.gutter + Metrics.columnSpacing)
                    .padding(.vertical, Spacing.m)
            }
            if let m = row.marker {
                MarkerLine(marker: m, id: id, time: time, gutter: layout.gutter)
                    .padding(.vertical, Spacing.m)
            } else {
                HStack(alignment: .top, spacing: Metrics.columnSpacing) {
                    Text(time)
                        .textStyle(.time)
                        .lineLimit(1)
                        .padding(.top, ScriptLayout.calloutDrop)
                        .frame(width: layout.gutter, alignment: .leading)
                        .help("\(Render.clock(row.start)) into the session")
                    SpeechCell(speech: row.speech)
                        .frame(width: layout.speech, alignment: .leading)
                    ActionsCell(actions: row.actions, expanded: expanded, expand: expand)
                        .padding(.top, ScriptLayout.calloutDrop)
                        .frame(width: layout.actions, alignment: .leading)
                    PicturesCell(pictures: row.pictures, layout: layout, open: open)
                        .frame(width: layout.pictures, alignment: .leading)
                }
                .padding(.vertical, Metrics.rowPadding)
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
                    Text(why).textStyle(.note).fixedSize(horizontal: false, vertical: true)
                }
            } else {
                Color.clear.frame(height: 1)
            }
        case .lost(let first):
            if first {
                Text(ScriptLayout.lost).textStyle(.note).fixedSize(horizontal: false, vertical: true)
            } else {
                Color.clear.frame(height: 1)
            }
        }
    }
}

private struct ActionsCell: View {
    let actions: [Script.Action]
    let expanded: Bool
    let expand: () -> Void

    var body: some View {
        let hidden = expanded ? 0 : max(0, actions.count - Metrics.actionsShown)
        VStack(alignment: .leading, spacing: Spacing.xs) {
            if actions.isEmpty { Color.clear.frame(height: 1) }
            ForEach(actions.prefix(actions.count - hidden)) { ActionLine(action: $0) }
            if hidden > 0 {
                Button("\(hidden) more", action: expand)
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
    let layout: ScriptLayout
    let open: (Int) -> Void

    var body: some View {
        if let first = pictures.first {
            let rest = Array(pictures.dropFirst())
            let (shown, more) = layout.smallPictures(rest.count)
            VStack(alignment: .leading, spacing: Spacing.xs) {
                picture(first, layout.firstPicture)
                if !rest.isEmpty {
                    HStack(spacing: Spacing.xs) {
                        ForEach(rest.prefix(shown)) { picture($0, Metrics.smallPicture) }
                        if more > 0 {
                            Button { open(rest[shown].id) } label: {
                                Text("+\(more)")
                                    .textStyle(.note)
                                    .frame(width: Metrics.smallPicture.width, height: Metrics.smallPicture.height)
                                    .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: Radius.medium))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        } else {
            Color.clear.frame(height: 1)
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
            Text(time).textStyle(.time).lineLimit(1).frame(width: gutter, alignment: .leading)
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
        .frame(height: 22)
    }
}
