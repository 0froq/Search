import SwiftUI

/// What you have taken off this site, and the way back.
///
/// A list of selectors is not something anyone can read. So resting the pointer
/// on a row puts that one thing back on the page, outlined, and scrolls to it —
/// you decide what to restore by looking at it, not by decoding its name.
struct HiddenPanel: View {
    @ObservedObject var browser: Browser

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text(browser.hereHost ?? "This page")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Palette.faint)
                    .textCase(.uppercase)
                    .tracking(0.6)
                Spacer(minLength: 0)
                if !browser.hereVeils.isEmpty {
                    Text("hover to see it")
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.faint)
                }
            }
            .padding(.horizontal, 6)
            .padding(.bottom, 10)

            if browser.hereVeils.isEmpty {
                Text("Nothing is hidden here.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Palette.muted)
                    .padding(.horizontal, 6)
                    .padding(.bottom, 4)
            } else {
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(browser.hereVeils) { veil in
                            Row(
                                veil: veil,
                                peek: { browser.peek(veil) },
                                restore: { browser.restore(veil) }
                            )
                        }
                    }
                }
                .frame(maxHeight: 300)
            }

            Divider().overlay(Palette.hairline).padding(.vertical, 12)

            HStack(spacing: 14) {
                Button("Hide something…") { browser.toggleHiding() }
                    .buttonStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.ink)
                if !browser.hereVeils.isEmpty {
                    Button("Restore all") { browser.restoreAll() }
                        .buttonStyle(.plain)
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.muted)
                }
                Spacer()
                Button("Done") { browser.reviewing = false }
                    .buttonStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.muted)
                    .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 6)
        }
        .padding(16)
        .frame(width: 340, alignment: .leading)
        .background(Palette.ground, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Palette.hairline, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.14), radius: 30, y: 10)
        // Leaving the panel puts the page back the way it was.
        .onHover { inside in
            if !inside { browser.stopPeeking() }
        }
    }

    private struct Row: View {
        let veil: Veil
        let peek: () -> Void
        let restore: () -> Void

        @State private var hovering = false

        var body: some View {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(veil.label)
                        .font(.system(size: 12.5))
                        .foregroundStyle(Palette.ink)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if let note = veil.note, !note.isEmpty {
                        Text(note)
                            .font(.system(size: 11))
                            .foregroundStyle(Palette.faint)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 8)

                Button(action: restore) {
                    Text("Restore")
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.ink)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4)
                        .background(Palette.ground, in: Capsule())
                        .overlay(Capsule().strokeBorder(Palette.hairline, lineWidth: 1))
                }
                .buttonStyle(.plain)
                .opacity(hovering ? 1 : 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(hovering ? Palette.wash : .clear)
            )
            .contentShape(Rectangle())
            .onHover { inside in
                hovering = inside
                if inside { peek() }
            }
            .animation(Motion.quick, value: hovering)
        }
    }
}
