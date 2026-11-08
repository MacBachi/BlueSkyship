import SwiftUI

/// The standard macOS settings window, reachable with ⌘,.
struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings()
                .tabItem { Label(tr("Allgemein", "General"), systemImage: "gearshape") }
            AccountSettings()
                .tabItem { Label(tr("Konten", "Accounts"), systemImage: "person.2") }
        }
        .frame(width: 460)
    }
}

private struct GeneralSettings: View {
    @Environment(DeckStore.self) private var deck

    var body: some View {
        @Bindable var settings = deck.settings
        @Bindable var localizer = Localizer.shared
        Form {
            Section(tr("Sprache", "Language")) {
                Picker(tr("Sprache der App", "App language"), selection: $localizer.preference) {
                    ForEach(LanguagePreference.allCases, id: \.self) { Text($0.label).tag($0) }
                }
            }
            Section(tr("Spalten", "Columns")) {
                Picker(tr("Automatisch aktualisieren", "Refresh automatically"), selection: $settings.refreshSeconds) {
                    ForEach(AppSettings.refreshChoices, id: \.seconds) { Text($0.label).tag($0.seconds) }
                }
                Picker(tr("Breite neuer Spalten", "Width of new columns"), selection: $settings.defaultWidth) {
                    ForEach(ColumnWidth.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                Toggle(tr("Bilder und Videos direkt anzeigen", "Show pictures and videos directly"), isOn: $settings.showMedia)
                Picker(tr("Textgröße der Posts", "Post text size"), selection: $settings.textSize) {
                    ForEach(PostTextSize.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                Toggle(tr("Tastatursteuerung (j, k, l, r …)", "Keyboard control (j, k, l, r…)"), isOn: $settings.keyboardShortcuts)
            }
            Section(tr("Mitteilungen", "Notifications")) {
                Toggle(tr("Anzahl am Dock-Symbol zeigen", "Show count on the Dock icon"), isOn: $settings.showDockBadge)
                    .onChange(of: settings.showDockBadge) { _, _ in deck.updateDockBadge() }
                Toggle(tr("macOS-Hinweise anzeigen", "Show macOS alerts"), isOn: $settings.showSystemNotifications)
                    .onChange(of: settings.showSystemNotifications) { _, isOn in
                        if isOn { Task { await deck.requestSystemNotificationPermission() } }
                    }
            }
            Section("iCloud") {
                Toggle(tr("Favoriten, Decks und Entwürfe synchronisieren", "Sync favorites, decks and drafts"), isOn: $settings.iCloudSync)
                    .onChange(of: settings.iCloudSync) { _, isOn in
                        if isOn { deck.syncWithCloud() }
                    }
                Text(tr("Anmeldungen und Bilder bleiben auf diesem Mac. Bei gleichzeitigen Änderungen auf zwei Macs gilt die spätere.", "Sign-ins and pictures stay on this Mac. When two Macs change something at once, the later change wins."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section(tr("Posten", "Posting")) {
                Toggle(tr("Bildbeschreibung verpflichtend", "Require image descriptions"), isOn: $settings.requireAltText)
                Picker(tr("Sprache neuer Posts", "Language of new posts"), selection: $settings.postLanguage) {
                    ForEach(AppSettings.languageChoices, id: \.code) { Text($0.label).tag($0.code) }
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct AccountSettings: View {
    @Environment(DeckStore.self) private var deck
    @Environment(\.openURL) private var openURL

    @State private var accountToRemove: Account?

    var body: some View {
        Form {
            Section(tr("Angemeldete Konten", "Signed-in accounts")) {
                if deck.accounts.accounts.isEmpty {
                    Text(tr("Noch kein Konto angemeldet.", "No account signed in yet.")).foregroundStyle(.secondary)
                }
                ForEach(deck.accounts.accounts) { account in
                    HStack(spacing: 10) {
                        Avatar(url: account.avatarURL, size: 28)
                        VStack(alignment: .leading, spacing: 0) {
                            Text(account.displayName?.isEmpty == false ? account.displayName! : account.handle)
                            Text("@\(account.handle)").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button(tr("Abmelden", "Sign Out")) { accountToRemove = account }
                    }
                }
            }
            Section {
                Button(tr("Konto hinzufügen …", "Add Account…")) { deck.isLoggingIn = true }
                Button(tr("App-Passwörter bei Bluesky verwalten", "Manage App Passwords on Bluesky")) { openURL(DeckStore.appPasswordsURL) }
            } footer: {
                Text(tr("Die App speichert nur Sitzungstoken im Schlüsselbund, nie dein Passwort.", "The app only stores session tokens in the Keychain, never your password."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .confirmationDialog(
            tr("@\(accountToRemove?.handle ?? "") abmelden?", "Sign out @\(accountToRemove?.handle ?? "")?"),
            isPresented: Binding(get: { accountToRemove != nil }, set: { if !$0 { accountToRemove = nil } }),
            titleVisibility: .visible
        ) {
            Button(tr("Abmelden", "Sign Out"), role: .destructive) {
                guard let did = accountToRemove?.did else { return }
                Task { await deck.logout(did: did) }
            }
        } message: {
            Text(tr("Spalten, die nur mit diesem Konto funktionieren, werden entfernt.", "Columns that only work with this account will be removed."))
        }
    }
}
