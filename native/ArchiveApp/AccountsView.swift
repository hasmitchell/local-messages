import SwiftUI

struct AccountMenu: View {
    @Environment(ArchiveModel.self) private var model
    var body: some View {
        Menu {
            ForEach(model.accounts) { profile in
                Button { model.switchAccount(profile) } label: {
                    if model.currentAccount?.id == profile.id { Label(profile.name, systemImage: "checkmark") }
                    else { Text(profile.name + (profile.setupComplete ? "" : " · Finish Setup")) }
                }
            }
            if !model.accounts.isEmpty { Divider() }
            Button("Add Account…", action: model.prepareNewAccount)
            Button("Manage Accounts…") { model.showingAccountSetup = false; model.showingAccounts = true }
            Divider()
            SettingsLink { Text("Settings…") }
        } label: {
            Label(model.accountName, systemImage: "person.crop.circle")
        }
        .help("Account: \(model.accountName). Switch, add or manage accounts.")
        .accessibilityLabel("Account: \(model.accountName)")
        .disabled(model.loading || model.savingSettings || model.stagingAttachments || model.pairingBusy)
    }
}

struct AccountsView: View {
    @Environment(ArchiveModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var pairing: RelinkController
    @State private var name = ""
    @FocusState private var nameFocused: Bool

    private var setupName: String { model.settingUpAccount?.name ?? name }
    private var title: String {
        switch pairing.state {
        case .ready: model.settingUpAccount == nil ? "Add an account" : "Finish account setup"
        case .cancelled: "Account setup cancelled"
        case .cancelling: "Cancelling account setup…"
        case .failed: "Account setup did not finish"
        case .verifyingPairing: "Saving this account…"
        case .complete: "Account added"
        default: pairing.state.title
        }
    }
    private var detail: String {
        switch pairing.state {
        case .ready: "Sign in to Google and confirm on your phone. This account gets its own archive, with the past year of available history and local cleanup off."
        case .verifyingAccount: "Checking the selected account and phone before creating its pairing."
        case .waitingForPhone: "Open Google Messages on the phone for this account and select the matching emoji."
        case .verifyingPairing: "Phone confirmation received. Saving this account’s pairing to Keychain."
        case .complete: "This account is now selected. Its available messages will download when sync is enabled. Your other accounts’ archives are kept."
        case .keychainError: "Check macOS Keychain access, then finish setup again. This account’s folder and identity have been kept so a retry can verify the same pairing."
        case .cancelled: "Your previous account is still selected. This unfinished setup is saved in the account list so you can continue later."
        default: pairing.state.detail
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(model.showingAccountSetup ? title : "Accounts").font(.title2.weight(.semibold))
                Spacer()
                if !pairing.busy { Button("Done") { dismiss() }.keyboardShortcut(.cancelAction) }
            }.padding(22)
            Divider()
            if model.showingAccountSetup { setup.padding(22) }
            else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        Text("Only the selected account syncs and shows notifications. Switch back to browse its saved history and catch up.")
                            .font(.callout).foregroundStyle(.secondary)
                        ForEach(model.accounts) { profile in AccountProfileRow(profile: profile) }
                        Button("Add Account…", action: model.prepareNewAccount).prominentButton()
                    }.padding(22)
                }.frame(maxHeight: 420)
            }
            if let error = model.accountError { Text(error).font(.callout).foregroundStyle(.orange).padding([.horizontal, .bottom], 22) }
        }.frame(width: 510)
        .interactiveDismissDisabled(pairing.busy)
        .onDisappear { if !pairing.busy { model.settingUpAccount = nil; model.showingAccountSetup = false } }
    }
    private var setup: some View {
        VStack(alignment: .leading, spacing: 18) {
            if pairing.state == .ready {
                if model.settingUpAccount == nil {
                    TextField("Account name, e.g. Personal or Work", text: $name)
                        .textFieldStyle(.roundedBorder).focused($nameFocused).accessibilityLabel("New account name")
                        .task { await Task.yield(); nameFocused = true }
                } else { Text(setupName).font(.headline) }
            }
            Text(detail).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let emoji = pairing.emoji, pairing.state == .waitingForPhone {
                Text(emoji).font(.system(size: 72)).frame(maxWidth: .infinity).accessibilityLabel("Pairing emoji: \(emoji)")
            } else if pairing.busy { ProgressView().frame(maxWidth: .infinity) }
            HStack {
                if !pairing.busy {
                    Button("All Accounts") { model.showingAccountSetup = false; model.settingUpAccount = nil }
                }
                Spacer()
                if pairing.busy {
                    Button("Cancel", action: pairing.cancel).disabled(pairing.state == .cancelling)
                } else if pairing.state != .complete {
                    Button(pairing.state == .ready ? "Sign In & Pair…" : "Try Again…") { model.addAccount(named: setupName) }
                        .prominentButton().keyboardShortcut(.defaultAction)
                        .disabled(!AccountStore.validName(setupName) || model.savingSettings || model.stagingAttachments || !model.accountListAvailable)
                }
            }
        }
    }
}

private struct AccountProfileRow: View {
    @Environment(ArchiveModel.self) private var model
    let profile: AccountProfile
    @State private var name = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: model.currentAccount?.id == profile.id ? "checkmark.circle.fill" : "person.crop.circle")
                    .foregroundStyle(.tint)
                TextField("Account name", text: $name).textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Account name: \(profile.name)")
                    .onSubmit { model.renameAccount(profile, to: name) }
                if name != profile.name {
                    Button("Save Name") { model.renameAccount(profile, to: name) }.disabled(!AccountStore.validName(name))
                }
                Button(profile.setupComplete ? "Switch" : "Finish Setup") { model.switchAccount(profile) }
                    .disabled(model.currentAccount?.id == profile.id || model.loading)
            }
            Text(!profile.setupComplete ? "Setup unfinished · Saved for retry" : model.currentAccount?.id == profile.id ? "Selected account" : "Saved on this Mac · Sync paused")
                .font(.caption).foregroundStyle(.secondary)
        }.padding(12).background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
            .onAppear { name = profile.name }.onChange(of: profile.name) { name = profile.name }
    }
}
