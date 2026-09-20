import SwiftUI

/// Every password kept, by site. The same white-and-hairline panel as the
/// rest, and the same rule: a password is never shown until you have proved
/// you are you, and never for longer than it takes to read it.
struct PasswordsPanel: View {
    @ObservedObject var browser: Browser

    @FocusState private var hunting: Bool
    @State private var open: String?
    @State private var adding = false
    @State private var importing: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            head
            search

            if browser.shownSites.isEmpty {
                Text(browser.saved.isEmpty
                     ? "Nothing kept yet. Bring yours in from another browser below."
                     : "Nothing matches.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Palette.muted)
                    .padding(.horizontal, 8)
                    .padding(.top, 16)
                    .padding(.bottom, 4)
            } else {
                list
            }

            if adding {
                Divider().overlay(Palette.hairline).padding(.vertical, 12)
                AddForm(browser: browser) { adding = false }
                    .transition(.opacity)
            }

            Divider().overlay(Palette.hairline).padding(.vertical, 12)
            foot
        }
        .padding(16)
        .frame(width: 520, alignment: .leading)
        .background(Palette.ground, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Palette.hairline, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.16), radius: 34, y: 12)
        .animation(Motion.settle, value: adding)
        .animation(Motion.settle, value: open)
        .onAppear { hunting = true }
    }

    private var head: some View {
        HStack(spacing: 8) {
            Text("Passwords")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Palette.faint)
                .textCase(.uppercase)
                .tracking(0.6)
            Spacer(minLength: 0)
            Text(browser.saved.count == 1 ? "1 password" : "\(browser.saved.count) passwords")
                .font(.system(size: 11))
                .foregroundStyle(Palette.faint)
            Pill(adding ? "Cancel" : "Add") { adding.toggle() }
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
                if browser.hunting.isEmpty {
                    Text("Search sites and accounts").foregroundStyle(Palette.ink.opacity(0.3))
                }
                TextField("", text: $browser.hunting)
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

    /// One line per site, opened to its accounts with a click.
    private var list: some View {
        ScrollView(showsIndicators: false) {
            LazyVStack(spacing: 2) {
                ForEach(browser.shownSites, id: \.host) { site in
                    Site(
                        host: site.host,
                        logins: site.logins,
                        open: open == site.host,
                        toggle: { open = open == site.host ? nil : site.host },
                        copy: { browser.copy($0) },
                        forget: { browser.forget($0) }
                    )
                }
            }
        }
        .frame(maxHeight: 440)
        .padding(.top, 8)
    }

    private var foot: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("Bring in from")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Palette.faint)
                    .textCase(.uppercase)
                    .tracking(0.6)
                if let importing {
                    Ring(size: 9)
                    Text("Reading \(importing)…")
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.faint)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)

            // Only the browsers actually on this Mac.
            HStack(spacing: 6) {
                ForEach(Chromium.installed()) { source in
                    Pill(source.name) {
                        importing = source.name
                        // Off the main thread: four hundred passwords is a
                        // moment of arithmetic, and the panel stays alive.
                        DispatchQueue.global(qos: .userInitiated).async {
                            let outcome = Result { try Chromium.read(source) }
                            DispatchQueue.main.async {
                                importing = nil
                                browser.took(outcome, from: source)
                            }
                        }
                    }
                    .disabled(importing != nil)
                }
                Pill("CSV file…") { browser.importPasswords() }
                    .disabled(importing != nil)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)

            HStack {
                Text("macOS will ask once for that browser's keychain key. Nothing is changed there.")
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.faint)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button("Done") { browser.managing = false }
                    .buttonStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.muted)
                    .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 8)
        }
    }

    /// A site, and under it its accounts once opened.
    private struct Site: View {
        let host: String
        let logins: [Login]
        let open: Bool
        let toggle: () -> Void
        let copy: (Login) -> Void
        let forget: (Login) -> Void

        @State private var hovering = false

        var body: some View {
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Mark(icon: Favicons.shared.cached(host), letter: host.first.map { String($0).uppercased() } ?? "•", size: 16)
                    Text(host)
                        .font(.system(size: 12.5))
                        .foregroundStyle(Palette.ink)
                        .lineLimit(1)
                    if logins.count > 1 {
                        Text("\(logins.count) accounts")
                            .font(.system(size: 11))
                            .foregroundStyle(Palette.faint)
                    } else if let only = logins.first, !only.user.isEmpty, !open {
                        Text(only.user)
                            .font(.system(size: 11))
                            .foregroundStyle(Palette.faint)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(Palette.faint)
                        .rotationEffect(.degrees(open ? 90 : 0))
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(open || hovering ? Palette.wash : .clear)
                )
                .contentShape(Rectangle())
                .onTapGesture(perform: toggle)
                .onHover { hovering = $0 }
                .animation(Motion.quick, value: hovering)

                if open {
                    VStack(spacing: 0) {
                        ForEach(logins) { login in
                            Account(login: login, copy: { copy(login) }, forget: { forget(login) })
                        }
                    }
                    .padding(.leading, 26)
                    .padding(.top, 2)
                    .padding(.bottom, 6)
                    .transition(.opacity)
                }
            }
        }
    }

    /// One account: the name, the password as dots, and the three things to
    /// do with it. Show asks the Mac who you are first.
    private struct Account: View {
        let login: Login
        let copy: () -> Void
        let forget: () -> Void

        @State private var hovering = false
        @State private var shown = false
        @State private var hide: DispatchWorkItem?

        var body: some View {
            HStack(spacing: 10) {
                Text(login.user.isEmpty ? "No username" : login.user)
                    .font(.system(size: 12))
                    .foregroundStyle(login.user.isEmpty ? Palette.faint : Palette.ink)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(minWidth: 120, alignment: .leading)

                Text(shown ? login.password : String(repeating: "•", count: min(12, max(6, login.password.count))))
                    .font(.system(size: shown ? 12 : 10, design: .monospaced))
                    .foregroundStyle(shown ? Palette.ink : Palette.muted)
                    .lineLimit(1)
                    .textSelection(.enabled)

                Spacer(minLength: 8)

                if hovering || shown {
                    Button(shown ? "Hide" : "Show") { shown ? conceal() : reveal() }
                        .buttonStyle(.plain)
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.ink)
                    Button("Copy", action: copy)
                        .buttonStyle(.plain)
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.ink)
                    Button("Remove", action: forget)
                        .buttonStyle(.plain)
                        .font(.system(size: 11))
                        .foregroundStyle(.red.opacity(0.7))
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(hovering ? Palette.hover : .clear)
            )
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .animation(Motion.quick, value: hovering)
            .animation(Motion.quick, value: shown)
            .onDisappear { conceal() }
        }

        private func reveal() {
            Vault.prove("show the password for \(login.host)") { ok in
                guard ok else { return }
                shown = true
                // Long enough to read or type across, and not a minute more.
                let work = DispatchWorkItem { shown = false }
                hide?.cancel()
                hide = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 15, execute: work)
            }
        }

        private func conceal() {
            hide?.cancel()
            shown = false
        }
    }

    /// Typing one in by hand. The site, the name, the password, and Save.
    private struct AddForm: View {
        @ObservedObject var browser: Browser
        let done: () -> Void

        @State private var site = ""
        @State private var user = ""
        @State private var password = ""
        @FocusState private var focus: Int?

        var body: some View {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    field("Site", text: $site, tag: 0)
                    field("Username", text: $user, tag: 1)
                }
                HStack(spacing: 8) {
                    ZStack(alignment: .leading) {
                        if password.isEmpty {
                            Text("Password").foregroundStyle(Palette.ink.opacity(0.3))
                                .padding(.leading, 10)
                        }
                        SecureField("", text: $password)
                            .textFieldStyle(.plain)
                            .font(.system(size: 12.5, design: .monospaced))
                            .foregroundStyle(Palette.ink)
                            .focused($focus, equals: 2)
                            .onSubmit(keep)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 7)
                    }
                    .background(Palette.wash, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                    Pill("Save", filled: true, action: keep)
                        .disabled(Vault.host(of: site).isEmpty || password.isEmpty)
                }
            }
            .padding(.horizontal, 8)
            .onAppear { focus = 0 }
        }

        private func field(_ name: String, text: Binding<String>, tag: Int) -> some View {
            ZStack(alignment: .leading) {
                if text.wrappedValue.isEmpty {
                    Text(name).foregroundStyle(Palette.ink.opacity(0.3)).padding(.leading, 10)
                }
                TextField("", text: text)
                    .textFieldStyle(.plain)
                    .foregroundStyle(Palette.ink)
                    .focused($focus, equals: tag)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
            }
            .font(.system(size: 12.5))
            .background(Palette.wash, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        }

        private func keep() {
            let host = Vault.host(of: site)
            guard !host.isEmpty, !password.isEmpty else { return }
            browser.keep(host: host, user: user.trimmingCharacters(in: .whitespaces), password: password)
            done()
        }
    }
}
