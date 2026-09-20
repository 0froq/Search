import SwiftUI
import WebKit

// A site's own icon, for the tabs that are set to wear one.
//
// WebKit doesn't hand these over, so the page is asked what it declares and
// the best of those is fetched once and kept as a small PNG next to the
// history. A tab brought back from yesterday's session has its icon before it
// has a page; a tab on a site never seen before shows a letter until the icon
// arrives, which is a second or so.

@MainActor
final class Favicons {
    static let shared = Favicons()

    /// Called with a host and its icon whenever one arrives, so every tab on
    /// that host can put it on at once.
    var arrived: ((String, NSImage) -> Void)?

    private var memory: [String: NSImage] = [:]
    private var busy: Set<String> = []
    private var missing: Set<String> = []

    private static var folder: URL { Store.folder.appendingPathComponent("icons", isDirectory: true) }
    private static func file(_ host: String) -> URL { folder.appendingPathComponent(host + ".png") }

    /// What is already known, and nothing fetched.
    func cached(_ host: String) -> NSImage? {
        if let hit = memory[host] { return hit }
        guard let image = NSImage(contentsOf: Favicons.file(host)) else { return nil }
        memory[host] = image
        return image
    }

    /// An icon from somewhere else — another browser's cache, at import —
    /// kept as if the site had handed it over, unless one is already here.
    func adopt(_ data: Data, for host: String) async {
        guard cached(host) == nil, let image = await Favicons.square(data) else { return }
        memory[host] = image
        Favicons.keep(image, for: host)
        arrived?(host, image)
    }

    /// Asks the page which icon it wants to be known by, fetches it, and keeps
    /// it. Nothing happens if a fresh one is already on disk.
    func fetch(for tab: Tab) {
        guard let url = tab.address, let host = url.host()?.lowercased(),
              url.scheme?.hasPrefix("http") == true
        else { return }

        if let stamp = try? Favicons.file(host).resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
           Date().timeIntervalSince(stamp) < 7 * 86_400,
           let known = cached(host) {
            tab.icon = known
            return
        }
        guard !busy.contains(host), !missing.contains(host) else { return }
        busy.insert(host)

        tab.web.evaluateJavaScript(Favicons.probe) { [weak self, weak tab] answer, _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let declared = (answer as? [[String: String]]) ?? []
                let candidates = Favicons.rank(declared, page: url)
                let shy = tab?.shy ?? false
                Task { await self.download(candidates, host: host, shy: shy) }
            }
        }
    }

    private func download(_ candidates: [URL], host: String, shy: Bool) async {
        defer { busy.remove(host) }
        let session = URLSession(configuration: {
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = 8
            return config
        }())
        for candidate in candidates {
            guard let (data, response) = try? await session.data(from: candidate),
                  (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? true,
                  data.count > 60, data.count < 2_000_000
            else { continue }
            guard let image = await Favicons.square(data) else { continue }
            memory[host] = image
            if !shy { Favicons.keep(image, for: host) }
            arrived?(host, image)
            return
        }
        // Not asked again this session: hammering a site for an icon it
        // doesn't have is exactly the kind of thing a quiet browser doesn't do.
        missing.insert(host)
    }

    /// Decoded and drawn into a square off the main thread — an .ico can hold
    /// a dozen sizes and take a moment to unpack.
    private static func square(_ data: Data) async -> NSImage? {
        await Task.detached(priority: .utility) { () -> NSImage? in
            guard let image = NSImage(data: data), image.isValid,
                  image.size.width > 0, image.size.height > 0
            else { return nil }
            let side: CGFloat = 64
            let out = NSImage(size: NSSize(width: side, height: side))
            out.lockFocus()
            NSGraphicsContext.current?.imageInterpolation = .high
            let scale = min(side / image.size.width, side / image.size.height)
            let w = image.size.width * scale
            let h = image.size.height * scale
            image.draw(
                in: NSRect(x: (side - w) / 2, y: (side - h) / 2, width: w, height: h),
                from: .zero,
                operation: .sourceOver,
                fraction: 1
            )
            out.unlockFocus()
            return out
        }.value
    }

    private static func keep(_ image: NSImage, for host: String) {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:])
        else { return }
        let file = Favicons.file(host)
        DispatchQueue.global(qos: .utility).async {
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try? png.write(to: file, options: .atomic)
        }
    }

    /// Best first. A crisp icon around 32–64 pixels is what a tab wants; the
    /// touch icon is a fine second; the file at the root is the fallback every
    /// site has had since 1999.
    private static func rank(_ declared: [[String: String]], page: URL) -> [URL] {
        var scored: [(URL, Int)] = []
        for entry in declared {
            guard let href = entry["href"], let url = URL(string: href),
                  url.scheme?.hasPrefix("http") == true
            else { continue }
            let rel = entry["rel"] ?? ""
            let sizes = entry["sizes"] ?? ""
            let type = entry["type"] ?? ""
            var score = 25
            if rel.contains("apple-touch") { score = 40 }
            if let px = sizes.split(separator: " ").compactMap({ Int($0.split(separator: "x").first ?? "") }).max() {
                switch px {
                case ..<24: score = 10
                case 24..<48: score = 45
                case 48..<128: score = 50
                case 128..<260: score = 42
                default: score = 20
                }
            }
            if sizes == "any" || type.contains("svg") || url.pathExtension.lowercased() == "svg" { score = 35 }
            scored.append((url, score))
        }
        var list = scored.sorted { $0.1 > $1.1 }.map(\.0)
        if let host = page.host(), let root = URL(string: "\(page.scheme ?? "https")://\(host)/favicon.ico") {
            list.append(root)
        }
        // The same address twice is a wasted request.
        var seen = Set<String>()
        return list.filter { seen.insert($0.absoluteString).inserted }
    }

    private static let probe = """
    (function () {
      var out = [];
      var links = document.querySelectorAll('link[rel]');
      for (var i = 0; i < links.length; i++) {
        var l = links[i];
        var rel = (l.getAttribute('rel') || '').toLowerCase();
        if (rel.indexOf('icon') < 0) continue;
        out.push({
          href: l.href,
          rel: rel,
          sizes: (l.getAttribute('sizes') || '').toLowerCase(),
          type: (l.getAttribute('type') || '').toLowerCase()
        });
      }
      return out;
    })();
    """
}

/// What stands for a page when there is no room for its title: the site's
/// icon if there is one, and a letter in a faint square until there is.
struct Mark: View {
    let icon: NSImage?
    let letter: String
    var size: CGFloat = 16
    var dim = false

    var body: some View {
        Group {
            if let icon {
                Image(nsImage: icon)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: size, height: size)
                    .clipShape(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
            } else {
                Text(letter)
                    .font(.system(size: size * 0.56, weight: .medium))
                    .foregroundStyle(Palette.muted)
                    .frame(width: size, height: size)
                    .background(
                        RoundedRectangle(cornerRadius: size * 0.22, style: .continuous)
                            .fill(Palette.ink.opacity(0.06))
                    )
            }
        }
        .opacity(dim ? 0.45 : 1)
        .transition(.opacity)
        .animation(Motion.quick, value: icon == nil)
    }
}
