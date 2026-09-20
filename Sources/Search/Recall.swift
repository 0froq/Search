import SwiftUI

/// Everywhere you have been, and everything you have kept. Two lists in the
/// same white-and-hairline panel as the rest, and in both cases the point is
/// as much being able to remove a line as to read one.

enum When {
    private static let ago: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()

    static func said(_ date: Date) -> String {
        ago.localizedString(for: date, relativeTo: Date())
    }

    private static let hour: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return formatter
    }()

    private static let plain: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "d MMMM"
        return formatter
    }()

    /// The time of day. Once a list is grouped by day, that is all a row needs.
    static func clock(_ date: Date) -> String { hour.string(from: date) }

    static func day(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return "Today" }
        if calendar.isDateInYesterday(date) { return "Yesterday" }
        return plain.string(from: date)
    }
}

struct HistoryPanel: View {
    @ObservedObject var browser: Browser

    @FocusState private var hunting: Bool
    @State private var traces: [History.Trace] = []
    @State private var clearing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            search

            if traces.isEmpty {
                Text(browser.recallHunt.isEmpty ? "Nothing yet." : "Nothing matches.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Palette.muted)
                    .padding(.horizontal, 8)
                    .padding(.top, 16)
            } else {
                list
            }

            Divider().overlay(Palette.hairline).padding(.vertical, 12)

            if clearing { sweeps } else { foot }
        }
        .padding(16)
        .frame(width: 420, alignment: .leading)
        .background(Palette.ground, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Palette.hairline, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.16), radius: 34, y: 12)
        .onAppear {
            hunting = true
            refresh()
        }
        .onChange(of: browser.recallHunt) { _, _ in refresh() }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("History")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Palette.faint)
                .textCase(.uppercase)
                .tracking(0.6)
            Spacer(minLength: 0)
            Text("\(traces.count)")
                .font(.system(size: 11))
                .foregroundStyle(Palette.faint)
        }
        .padding(.horizontal, 8)
        .padding(.bottom, 10)
    }

    private var search: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(Palette.faint)
            ZStack(alignment: .leading) {
                if browser.recallHunt.isEmpty {
                    Text("Search").foregroundStyle(Palette.ink.opacity(0.3))
                }
                TextField("", text: $browser.recallHunt)
                    .textFieldStyle(.plain)
                    .foregroundStyle(Palette.ink)
                    .focused($hunting)
            }
            .font(.system(size: 12.5))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Palette.wash, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }

    /// Grouped by day, because that is how anybody looks for a page they saw
    /// once — not by an exact minute, but by "it was this morning".
    private var list: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                ForEach(days, id: \.0) { day, rows in
                    Section {
                        ForEach(rows) { trace in
                            Row(
                                trace: trace,
                                go: {
                                    browser.recalling = false
                                    browser.active?.go(to: trace.url)
                                },
                                forget: {
                                    browser.history.forget(trace.key)
                                    refresh()
                                }
                            )
                        }
                    } header: {
                        Text(day)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(Palette.faint)
                            .textCase(.uppercase)
                            .tracking(0.6)
                            .padding(.horizontal, 8)
                            .padding(.top, 14)
                            .padding(.bottom, 6)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Palette.ground)
                    }
                }
            }
        }
        .frame(maxHeight: 330)
    }

    private var foot: some View {
        HStack(spacing: 16) {
            Button("Clear data…") { withAnimation(Motion.settle) { clearing = true } }
                .buttonStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(Palette.ink)
            Spacer()
            Button("Done") { browser.recalling = false }
                .buttonStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(Palette.muted)
                .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 8)
    }

    /// Three separate things, worded so nobody has to guess which one signs
    /// them out of their bank.
    private var sweeps: some View {
        VStack(alignment: .leading, spacing: 0) {
            sweep("Clear history", "everywhere you have been") {
                browser.clearHistory()
                refresh()
            }
            sweep("Sign out of everything", "cookies and stored sessions") {
                browser.clearSites()
            }
            sweep("Clear cache", "only what was fetched to draw pages") {
                browser.clearCache()
            }

            HStack {
                Button("Back") { withAnimation(Motion.settle) { clearing = false } }
                    .buttonStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.muted)
                Spacer()
                Button("Done") { browser.recalling = false }
                    .buttonStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.muted)
                    .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 8)
            .padding(.top, 12)
        }
        .transition(.opacity)
    }

    private func sweep(
        _ title: String,
        _ detail: String,
        action: @escaping () -> Void
    ) -> some View {
        Sweep(title: title, detail: detail, action: action)
    }

    private var days: [(String, [History.Trace])] {
        let calendar = Calendar.current
        let grouped = Dictionary(grouping: traces) { calendar.startOfDay(for: $0.last) }
        return grouped.keys.sorted(by: >).map { day in
            (When.day(day), grouped[day]!.sorted { $0.last > $1.last })
        }
    }

    private func refresh() {
        traces = browser.history.everything(matching: browser.recallHunt)
    }

    private struct Sweep: View {
        let title: String
        let detail: String
        let action: () -> Void

        @State private var hovering = false

        var body: some View {
            Button(action: action) {
                HStack(spacing: 8) {
                    Text(title)
                        .font(.system(size: 12.5))
                        .foregroundStyle(Palette.ink)
                    Text(detail)
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.faint)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(hovering ? Palette.wash : .clear)
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .animation(Motion.quick, value: hovering)
        }
    }

    /// One line. A title, where it came from, and when — the three things you
    /// scan for, in the order you scan them.
    private struct Row: View {
        let trace: History.Trace
        let go: () -> Void
        let forget: () -> Void

        @State private var hovering = false

        var body: some View {
            HStack(spacing: 10) {
                Text(trace.title.isEmpty ? trace.key : trace.title)
                    .font(.system(size: 12.5))
                    .foregroundStyle(Palette.ink)
                    .lineLimit(1)
                    .layoutPriority(1)

                Text(trace.key)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Palette.faint)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer(minLength: 8)

                if hovering {
                    Button("Remove", action: forget)
                        .buttonStyle(.plain)
                        .font(.system(size: 11))
                        .foregroundStyle(.red.opacity(0.7))
                } else {
                    Text(When.clock(trace.last))
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.faint)
                        .monospacedDigit()
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(hovering ? Palette.wash : .clear)
            )
            .contentShape(Rectangle())
            .onTapGesture(perform: go)
            .onHover { hovering = $0 }
            .animation(Motion.quick, value: hovering)
        }
    }
}

struct DownloadsPanel: View {
    @ObservedObject var browser: Browser
    @ObservedObject var loot: Loot

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text("Downloads")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Palette.faint)
                    .textCase(.uppercase)
                    .tracking(0.6)
                Spacer(minLength: 0)
                Text("\(loot.kept.count)")
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.faint)
            }
            .padding(.horizontal, 6)
            .padding(.bottom, 10)

            if loot.kept.isEmpty {
                Text("Nothing kept yet.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Palette.muted)
                    .padding(.horizontal, 6)
            } else {
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(loot.kept) { keep in
                            Row(
                                keep: keep,
                                open: { loot.open(keep) },
                                reveal: { loot.reveal(keep) },
                                forget: { loot.forget(keep) }
                            )
                        }
                    }
                }
                .frame(maxHeight: 300)
            }

            Divider().overlay(Palette.hairline).padding(.vertical, 12)

            HStack(spacing: 16) {
                if !loot.kept.isEmpty {
                    Button("Clear list") { loot.forgetAll() }
                        .buttonStyle(.plain)
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.ink)
                    Text("the files stay where they are")
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.faint)
                }
                Spacer()
                Button("Done") { browser.hoarding = false }
                    .buttonStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.muted)
                    .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 6)
        }
        .padding(16)
        .frame(width: 380, alignment: .leading)
        .background(Palette.ground, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Palette.hairline, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.16), radius: 34, y: 12)
    }

    private struct Row: View {
        let keep: Keep
        let open: () -> Void
        let reveal: () -> Void
        let forget: () -> Void

        @State private var hovering = false

        var body: some View {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(keep.name)
                        .font(.system(size: 12.5))
                        .foregroundStyle(keep.stillThere ? Palette.ink : Palette.faint)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(keep.from.isEmpty ? When.said(keep.date) : "\(keep.from) · \(When.said(keep.date))")
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.faint)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                if hovering {
                    if keep.stillThere {
                        Button("Show", action: reveal)
                            .buttonStyle(.plain)
                            .font(.system(size: 11))
                            .foregroundStyle(Palette.ink)
                    }
                    Button("Remove", action: forget)
                        .buttonStyle(.plain)
                        .font(.system(size: 11))
                        .foregroundStyle(.red.opacity(0.7))
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(hovering ? Palette.wash : .clear)
            )
            .contentShape(Rectangle())
            .onTapGesture { if keep.stillThere { open() } }
            .onHover { hovering = $0 }
            .animation(Motion.quick, value: hovering)
        }
    }
}
