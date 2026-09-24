import AppKit
import CarKit
import SwiftUI

// A picture, big, over the script: the picture as large as the pane allows,
// and under it when it was taken, why, and what was being said. ← and → step
// through every picture in the session; Esc, space, a click beside it or the
// close button put it away. The one dark surface in car, the way a photo is
// shown anywhere on a Mac.
struct PictureViewer: View {
    let script: Script
    @Binding var viewing: Int?
    @FocusState private var focused: Bool
    @State private var image: NSImage?

    var body: some View {
        let pictures = script.pictures
        if let i = pictures.firstIndex(where: { $0.id == viewing }) {
            let p = pictures[i]
            ZStack {
                Rectangle()
                    .fill(.black.opacity(0.9))
                    .onTapGesture { viewing = nil }
                VStack(spacing: Spacing.l) {
                    ZStack {
                        if let image {
                            Image(nsImage: image).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
                        } else {
                            ProgressView().controlSize(.small)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    caption(p, index: i, of: pictures.count)
                }
                .padding(.horizontal, Spacing.xxl + Spacing.xl)
                .padding(.vertical, Spacing.xl)
                HStack {
                    step(-1, "chevron.left", enabled: i > 0)
                    Spacer()
                    step(1, "chevron.right", enabled: i < pictures.count - 1)
                }
                .padding(.horizontal, Spacing.m)
                Button { viewing = nil } label: {
                    Image(systemName: "xmark").font(.title3.weight(.semibold)).frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white.opacity(0.8))
                .help("Close (Esc)")
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                .padding(Spacing.l)
            }
            .environment(\.colorScheme, .dark)
            .focusable()
            .focused($focused)
            .focusEffectDisabled()
            .onAppear { focused = true }
            .onKeyPress(.leftArrow) { go(-1); return .handled }
            .onKeyPress(.rightArrow) { go(1); return .handled }
            .onKeyPress(.space) { viewing = nil; return .handled }
            .onExitCommand { viewing = nil }
            .task(id: p.id) {
                image = await Pictures.thumbnail(p.url, pixels: 440)
                image = await Pictures.full(p.url) ?? image
            }
            .transition(.opacity)
        }
    }

    private func caption(_ p: Script.Picture, index: Int, of count: Int) -> some View {
        let said = script.rows.first { $0.pictures.contains { $0.id == p.id } }.flatMap { row -> String? in
            if case .said(let text) = row.speech { return text }
            return nil
        }
        return VStack(spacing: Spacing.xs) {
            Text([script.date(p.t).map(Format.timeSeconds), p.reason, "\(index + 1) of \(count)"]
                .compactMap { $0 }.joined(separator: " · "))
                .textStyle(.subtitle)
            if let said {
                Text(Said.styled(said))
                    .textStyle(.speech)
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
                    .frame(maxWidth: 640)
            }
        }
    }

    private func step(_ by: Int, _ symbol: String, enabled: Bool) -> some View {
        Button { go(by) } label: {
            Image(systemName: symbol).font(.title2.weight(.semibold)).frame(width: 36, height: 56).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white.opacity(enabled ? 0.8 : 0.2))
        .disabled(!enabled)
    }

    private func go(_ by: Int) {
        let pictures = script.pictures
        guard let i = pictures.firstIndex(where: { $0.id == viewing }), pictures.indices.contains(i + by) else { return }
        viewing = pictures[i + by].id
    }
}
