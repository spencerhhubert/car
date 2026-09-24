import AppKit
import CarKit
import SwiftUI

// The pieces the windows are made of, each drawn one way everywhere. When a
// view needs one of these things, it uses this one; a new kind of thing is
// added here and to docs/design-system/components.md.

/// A session is recording.
struct RecordingDot: View {
    var body: some View {
        Circle().fill(Tint.recording).frame(width: 7, height: 7).accessibilityLabel("Recording")
    }
}

/// Where words are still to come: two grey lines holding their place, and on
/// the first row of a stretch, what they are waiting for.
struct Pending: View {
    let label: String?
    let recording: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            if let label {
                HStack(spacing: Spacing.s) {
                    if recording { RecordingDot() } else { ProgressView().controlSize(.mini) }
                    Text(label).textStyle(.note)
                }
            }
            line(Metrics.pendingLines.long)
            line(Metrics.pendingLines.short)
        }
        .alignmentGuide(.firstTextBaseline) { d in label == nil ? d[.top] + Metrics.firstLine : d[.firstTextBaseline] }
        .accessibilityElement(children: .combine)
    }

    private func line(_ width: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: Radius.small).fill(.fill.secondary).frame(maxWidth: width).frame(height: 8)
    }
}

/// A picture, small: filling a box of a fixed size (the whole picture is a
/// click away), so a list of them never jumps as they load. Made from the
/// file off the main thread and kept in a cache of a bounded size (Pictures).
struct Thumbnail: View {
    let url: URL
    let size: CGSize
    @State private var image: NSImage?

    var body: some View {
        ZStack(alignment: .top) {
            Rectangle().fill(.fill.tertiary)
            if let image {
                Image(nsImage: image).resizable().interpolation(.high).aspectRatio(contentMode: .fill)
                    .frame(width: size.width, height: size.height, alignment: .top)
            }
        }
        .frame(width: size.width, height: size.height)
        .clipShape(RoundedRectangle(cornerRadius: Radius.medium))
        .overlay(RoundedRectangle(cornerRadius: Radius.medium).strokeBorder(.separator))
        .task(id: url) { image = await Pictures.thumbnail(url, pixels: Int(max(size.width, size.height) * 2)) }
        .onDisappear { image = nil }
    }
}

/// What a session is doing, next to its title: nothing when it is done.
struct StatusBadge: View {
    let status: Script.Status

    var body: some View {
        switch status {
        case .recording:
            HStack(spacing: Spacing.s) { RecordingDot(); Text("Recording").textStyle(.subtitle) }
        case .transcribing:
            HStack(spacing: Spacing.s) { ProgressView().controlSize(.mini); Text("Transcribing").textStyle(.subtitle) }
        case .failed(let why):
            Label("Not all transcribed", systemImage: "exclamationmark.triangle.fill")
                .textStyle(.subtitle)
                .symbolRenderingMode(.multicolor)
                .help(why)
        case .done:
            EmptyView()
        }
    }
}

extension Script.Action.Kind {
    /// Its symbol in the actions column.
    var symbol: String {
        switch self {
        case .app: "macwindow.on.rectangle"
        case .window: "macwindow"
        case .page: "globe"
        case .finder: "folder"
        case .click: "cursorarrow.click"
        case .key: "command"
        case .typed: "keyboard"
        case .select: "text.cursor"
        case .scroll: "arrow.up.and.down"
        case .mark: "pencil.tip"
        case .clear: "trash"
        case .desk: "text.page"
        case .dictation: "text.quote"
        }
    }
}

extension Metrics {
    /// A cell with no text (pictures, placeholder lines) puts its top this
    /// far above the row's first baseline: level with the top of the words.
    static let firstLine: CGFloat = 12
    static let pendingLines: (long: CGFloat, short: CGFloat) = (260, 170)
}

/// What was said, with each mark drawn during it ("{red circle 1}") set in
/// the mark's own ink.
enum Said {
    static func styled(_ text: String) -> AttributedString {
        var out = AttributedString()
        var rest = Substring(text)
        while let open = rest.firstIndex(of: "{"), let close = rest[open...].firstIndex(of: "}") {
            out += AttributedString(rest[..<open])
            let name = rest[rest.index(after: open)..<close]
            var mark = AttributedString(name)
            if let ink = name.split(separator: " ").first.flatMap({ Ink(rawValue: String($0)) }) {
                mark.swiftUI.foregroundColor = Tint.ink(ink)
            }
            mark.swiftUI.font = TextStyle.speech.font.weight(.medium)
            out += mark
            rest = rest[rest.index(after: close)...]
        }
        out += AttributedString(rest)
        return out
    }
}
