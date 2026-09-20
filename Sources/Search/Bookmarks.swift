import AppKit
import SwiftUI

// Bookmarks: folders and sites, kept in a small file, shown as a menu.
//
// The menu is the system's own. A folder opens on hover, a site opens on
// click, and the whole thing closes the way every other menu on the Mac
// does — which is exactly what a person expects of a list of places, and
// nothing a hand-drawn dropdown gets right on the first try.

struct Bookmark: Codable, Identifiable, Hashable {
    var id = UUID()
    var title: String
    /// Nil for a folder.
    var url: String?
    var children: [Bookmark]?

    var isFolder: Bool { url == nil }

    static func site(_ title: String, _ url: URL) -> Bookmark {
        Bookmark(title: title.isEmpty ? Address.pretty(url) : title, url: url.absoluteString, children: nil)
    }

    static func folder(_ title: String, _ children: [Bookmark]) -> Bookmark {
        Bookmark(title: title, url: nil, children: children)
    }
}

@MainActor
final class Bookmarks: ObservableObject {
    @Published private(set) var roots: [Bookmark] = []

    init() { load() }

    var isEmpty: Bool { roots.isEmpty }

    /// How many sites, folders included.
    var count: Int { Bookmarks.count(roots) }

    static func count(_ nodes: [Bookmark]) -> Int {
        nodes.reduce(0) { $0 + ($1.isFolder ? count($1.children ?? []) : 1) }
    }

    /// Every site in the list, in order, folders opened.
    static func urls(_ nodes: [Bookmark]) -> [URL] {
        nodes.flatMap { node -> [URL] in
            if node.isFolder { return urls(node.children ?? []) }
            return node.url.flatMap(URL.init(string:)).map { [$0] } ?? []
        }
    }

    // MARK: - changing

    /// The page, at the end of the list. Nothing is asked: the title is the
    /// page's, and moving it into a folder is a job for the panel.
    func add(_ url: URL, title: String) {
        guard !contains(url) else { return }
        roots.append(.site(title, url))
        save()
    }

    func contains(_ url: URL) -> Bool {
        func walk(_ nodes: [Bookmark]) -> Bool {
            nodes.contains { $0.url == url.absoluteString || walk($0.children ?? []) }
        }
        return walk(roots)
    }

    func remove(_ id: Bookmark.ID) {
        func prune(_ nodes: [Bookmark]) -> [Bookmark] {
            nodes.compactMap { node in
                if node.id == id { return nil }
                var copy = node
                if let kids = node.children { copy.children = prune(kids) }
                return copy
            }
        }
        roots = prune(roots)
        save()
    }

    /// Another browser's, kept apart in a folder of that browser's name
    /// unless there was nothing here yet.
    func take(_ nodes: [Bookmark], from name: String) {
        guard !nodes.isEmpty else { return }
        if roots.isEmpty {
            roots = nodes
        } else {
            roots.removeAll { $0.isFolder && $0.title == name }
            roots.append(.folder(name, nodes))
        }
        save()
    }

    // MARK: - as a menu

    /// The list, as the menu it is shown in. Folders become submenus; sites
    /// carry their icon when one is known.
    func menu(open: @escaping (URL) -> Void, manage: @escaping () -> Void, addHere: @escaping () -> Void) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        if roots.isEmpty {
            let empty = NSMenuItem(title: "No bookmarks yet", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        } else {
            fill(menu, with: roots, open: open)
        }
        menu.addItem(.separator())
        menu.addItem(Bookmarks.item("Add This Page", "bookmark", addHere))
        menu.addItem(Bookmarks.item("Manage Bookmarks…", nil, manage))
        return menu
    }

    private func fill(_ menu: NSMenu, with nodes: [Bookmark], open: @escaping (URL) -> Void) {
        for node in nodes {
            if node.isFolder {
                let item = NSMenuItem(title: node.title, action: nil, keyEquivalent: "")
                item.image = Bookmarks.glyph("folder")
                let sub = NSMenu(title: node.title)
                sub.autoenablesItems = false
                if let kids = node.children, !kids.isEmpty {
                    fill(sub, with: kids, open: open)
                } else {
                    let empty = NSMenuItem(title: "Empty", action: nil, keyEquivalent: "")
                    empty.isEnabled = false
                    sub.addItem(empty)
                }
                item.submenu = sub
                menu.addItem(item)
            } else if let text = node.url, let url = URL(string: text) {
                // A page's own title can run to a sentence; a menu is not
                // the place for it.
                let title = node.title.count > 60 ? String(node.title.prefix(58)).trimmingCharacters(in: .whitespaces) + "…" : node.title
                let item = Bookmarks.item(title, nil) { open(url) }
                item.image = Bookmarks.icon(for: url)
                item.toolTip = Address.pretty(url)
                menu.addItem(item)
            }
        }
    }

    /// A menu item that runs a closure. NSMenuItem wants a target and a
    /// selector; this keeps the two together.
    private static func item(_ title: String, _ symbol: String?, _ act: @escaping () -> Void) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(Runner.run), keyEquivalent: "")
        let runner = Runner(act)
        item.target = runner
        item.representedObject = runner
        if let symbol { item.image = glyph(symbol) }
        return item
    }

    private final class Runner: NSObject {
        let act: () -> Void
        init(_ act: @escaping () -> Void) { self.act = act }
        @objc func run() { act() }
    }

    private static func glyph(_ symbol: String) -> NSImage? {
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        return image?.withSymbolConfiguration(.init(pointSize: 12, weight: .regular))
    }

    /// The site's icon at menu size, or a small plate with its letter.
    private static func icon(for url: URL) -> NSImage {
        let host = url.host()?.lowercased() ?? ""
        if let cached = Favicons.shared.cached(host) {
            let copy = cached.copy() as! NSImage
            copy.size = NSSize(width: 16, height: 16)
            return copy
        }
        let letter = String(host.replacingOccurrences(of: "www.", with: "").prefix(1)).uppercased()
        let image = NSImage(size: NSSize(width: 16, height: 16), flipped: false) { rect in
            NSColor(white: 0.93, alpha: 1).setFill()
            NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4).fill()
            let text = NSAttributedString(string: letter, attributes: [
                .font: NSFont.systemFont(ofSize: 9, weight: .medium),
                .foregroundColor: NSColor(white: 0.45, alpha: 1),
            ])
            let size = text.size()
            text.draw(at: NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2))
            return true
        }
        return image
    }

    // MARK: - the file

    private static var file: URL { Store.file("bookmarks.json") }

    private func load() {
        guard let data = try? Data(contentsOf: Bookmarks.file) else { return }
        guard let list = try? JSONDecoder().decode([Bookmark].self, from: data) else {
            Store.quarantine(Bookmarks.file)
            return
        }
        roots = list
    }

    private func save() {
        let snapshot = roots
        let file = Bookmarks.file
        DispatchQueue.global(qos: .utility).async {
            guard let data = try? JSONEncoder().encode(snapshot) else { return }
            try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: file, options: .atomic)
        }
    }
}

/// Where the menu comes out of: an empty AppKit view under the SwiftUI
/// button, so the menu can be told exactly which corner to hang from.
struct MenuAnchor: NSViewRepresentable {
    let pop: Int
    let menu: () -> NSMenu

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ view: NSView, context: Context) {
        guard pop != context.coordinator.shown, pop > 0 else { return }
        context.coordinator.shown = pop
        let menu = menu()
        DispatchQueue.main.async {
            menu.popUp(positioning: nil, at: NSPoint(x: view.bounds.minX, y: view.bounds.minY - 6), in: view)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator { var shown = 0 }
}

/// The list of everything kept, for taking things out of it.
struct BookmarksPanel: View {
    @ObservedObject var browser: Browser
    @ObservedObject var bookmarks: Bookmarks

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text("Bookmarks")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Palette.faint)
                    .textCase(.uppercase)
                    .tracking(0.6)
                Spacer(minLength: 0)
                Text("\(bookmarks.count)")
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.faint)
            }
            .padding(.horizontal, 6)
            .padding(.bottom, 10)

            if bookmarks.isEmpty {
                Text("Nothing kept yet. Bring yours in below, or add this page with ⇧⌘B.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Palette.muted)
                    .padding(.horizontal, 6)
            } else {
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(flattened, id: \.node.id) { entry in
                            Row(
                                node: entry.node,
                                path: entry.path,
                                open: {
                                    if let text = entry.node.url, let url = URL(string: text) {
                                        browser.bookmarking = false
                                        browser.visit(url)
                                    }
                                },
                                forget: { bookmarks.remove(entry.node.id) }
                            )
                        }
                    }
                }
                .frame(maxHeight: 360)
            }

            Divider().overlay(Palette.hairline).padding(.vertical, 12)

            HStack(spacing: 6) {
                ForEach(Chromium.installed()) { source in
                    Pill(source.name) { browser.takeBookmarks(from: source) }
                }
                Spacer()
                Button("Done") { browser.bookmarking = false }
                    .buttonStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.muted)
                    .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 6)
        }
        .padding(16)
        .frame(width: 420, alignment: .leading)
        .background(Palette.ground, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Palette.hairline, lineWidth: 1))
        .shadow(color: .black.opacity(0.16), radius: 34, y: 12)
    }

    private var flattened: [(node: Bookmark, path: String)] {
        var out: [(Bookmark, String)] = []
        func walk(_ nodes: [Bookmark], _ path: [String]) {
            for node in nodes {
                if node.isFolder {
                    walk(node.children ?? [], path + [node.title])
                } else {
                    out.append((node, path.joined(separator: " / ")))
                }
            }
        }
        walk(bookmarks.roots, [])
        return out
    }

    private struct Row: View {
        let node: Bookmark
        let path: String
        let open: () -> Void
        let forget: () -> Void
        @State private var hovering = false

        var body: some View {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(node.title)
                        .font(.system(size: 12.5))
                        .foregroundStyle(Palette.ink)
                        .lineLimit(1)
                    if !path.isEmpty {
                        Text(path)
                            .font(.system(size: 11))
                            .foregroundStyle(Palette.faint)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                if hovering {
                    Button("Remove", action: forget)
                        .buttonStyle(.plain)
                        .font(.system(size: 11))
                        .foregroundStyle(.red.opacity(0.7))
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(hovering ? Palette.wash : .clear))
            .contentShape(Rectangle())
            .onTapGesture(perform: open)
            .onHover { hovering = $0 }
            .animation(Motion.quick, value: hovering)
        }
    }
}
