import SwiftUI
import AppKit

/// Instellingen → Telegram: your own bot, the accounts that may talk to it, and the notifications.
struct TelegramSettingsView: View {
    @EnvironmentObject var settings: Settings
    @ObservedObject private var service = TelegramService.shared
    @State private var token = ""
    @State private var hasToken = TelegramService.shared.token != nil
    @State private var now = Date()
    private let clock = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        Form {
            Section {
                HStack(alignment: .top) {
                    Text(L("Praat via Telegram met het model op deze Mac, ook als je er niet bent. Het model blijft op de Mac; je berichten en de antwoorden gaan wel via de servers van Telegram."))
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    HelpButton(topic: "telegram")
                }
                Toggle(L("Telegram"), isOn: $settings.featureTelegram)
                    .onChange(of: settings.featureTelegram) { _, _ in service.restart() }
                LabeledContent(L("Status"), value: statusText)
            }

            Section(L("Bot")) {
                if hasToken {
                    HStack {
                        Text(L("Token staat in de sleutelhanger."))
                        Spacer()
                        Button(L("Verwijder token"), role: .destructive) {
                            service.setToken("")
                            hasToken = false
                        }
                    }
                } else {
                    Text(L("1. Open Telegram en zoek @BotFather.\n2. Stuur /newbot en kies een naam.\n3. Plak hier de token die je krijgt."))
                        .font(.caption)
                    HStack {
                        SecureField(L("Token"), text: $token)
                        Button(L("Bewaar")) {
                            service.setToken(token)
                            token = ""
                            hasToken = service.token != nil
                        }
                        .disabled(token.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
            }

            Section(L("Wie mag praten")) {
                if service.accounts.isEmpty {
                    Text(L("Nog niemand. Alleen een gekoppeld account krijgt antwoord; berichten van anderen negeert de bot."))
                        .font(.caption).foregroundStyle(.secondary)
                }
                ForEach(service.accounts) { a in
                    HStack {
                        Text(a.name)
                        Text(String(a.id)).font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button(L("Ontkoppelen")) { service.unpair(a.id) }
                    }
                }
                if let code = service.code, let until = service.access.codeUntil, until > now {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(L("Stuur deze code naar je bot in Telegram:"))
                        Text(code).font(.system(size: 28, weight: .semibold, design: .monospaced)).textSelection(.enabled)
                        Text(L("Nog \(Int(until.timeIntervalSince(now)) / 60 + 1) min geldig.")).font(.caption).foregroundStyle(.secondary)
                        Button(L("Annuleer")) { service.cancelCode() }
                    }
                } else {
                    Button(L("Koppel een account")) { _ = service.newCode() }
                        .disabled(!service.isOnline)
                }
            }

            Section(L("Meldingen")) {
                Toggle(L("Taken en heartbeat ook naar Telegram"), isOn: $settings.telegramNotify)
                Text(L("Naar het eerst gekoppelde account: een taak klaar of gestopt, wat de heartbeat vond, en een goedkeuring die een taak nodig heeft (met knoppen). Beheerdersrechten keur je altijd op de Mac goed."))
                    .font(.caption).foregroundStyle(.secondary)
            }

            if !service.log.isEmpty {
                Section(L("Log")) {
                    ScrollView {
                        Text(service.log.suffix(20).joined(separator: "\n"))
                            .font(.caption.monospaced()).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                    }
                    .frame(height: 90)
                }
            }
        }
        .formStyle(.grouped)
        .onReceive(clock) { now = $0 }
    }

    private var statusText: String {
        switch service.status {
        case .off: return L("Uit")
        case .noToken: return L("Nog geen token")
        case .connecting: return L("Verbinden…")
        case .online(let name): return L("Verbonden als \(name)")
        case .problem(let why): return why
        }
    }
}
