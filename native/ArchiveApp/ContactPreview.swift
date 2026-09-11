import AppKit
import SwiftUI

struct ContactPreview: View {
    @Environment(\.dismiss) private var dismiss
    let url: URL
    @State private var contacts: [SharedContact]?
    @State private var error: String?
    @State private var openingError: String?
    @State private var importResult: String?
    @State private var importing = false
    @State private var googleContainer: ContactImporter.Container?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("Shared contact", systemImage: "person.crop.rectangle").font(.headline)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }.padding(20)
            Divider()
            ScrollView {
                if let contacts {
                    VStack(alignment: .leading, spacing: 24) {
                        ForEach(contacts) { contact in
                            VStack(alignment: .leading, spacing: 16) {
                                HStack(spacing: 14) {
                                    Image(systemName: "person.crop.circle.fill").font(.system(size: 44)).foregroundStyle(archiveAccent)
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(verbatim: contact.name).font(.title2.weight(.semibold))
                                        if !contact.organization.isEmpty && contact.organization != contact.name {
                                            Text(verbatim: contact.organization).foregroundStyle(.secondary)
                                        }
                                    }
                                }
                                ForEach(contact.fields) { field in
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(verbatim: field.label).font(.caption).foregroundStyle(.secondary)
                                        Text(verbatim: field.value).textSelection(.enabled)
                                    }
                                }
                                if contact.fields.isEmpty { Text("No phone number or other contact details in this card.").foregroundStyle(.secondary) }
                            }.frame(maxWidth: .infinity, alignment: .leading)
                            if contact.id != contacts.last?.id { Divider() }
                        }
                    }.textSelection(.enabled).padding(24)
                } else if let error {
                    ContentUnavailableView("Contact preview unavailable", systemImage: "person.crop.rectangle", description: Text(error)).padding(24)
                } else { ProgressView("Reading contact…").padding(40) }
            }
            Divider()
            VStack(alignment: .leading, spacing: 10) {
                if let openingError { Text(openingError).foregroundStyle(.red).font(.callout) }
                if let importResult { Text(importResult).foregroundStyle(.secondary).font(.callout) }
                HStack(spacing: 8) {
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                    Button("Open in Contacts…", action: openInContacts).disabled(contacts == nil)
                    Spacer()
                    if importing { ProgressView().controlSize(.small) }
                    if let googleContainer {
                        Button("Add to Google Contacts") { add(to: googleContainer) }.buttonStyle(.borderedProminent).disabled(contacts == nil || importing)
                            .help("Saves into the \(googleContainer.name) account in macOS Contacts, which syncs to your phone")
                    }
                    if googleContainer == nil {
                        Button("Add to Contacts") { add(to: nil) }.buttonStyle(.borderedProminent).disabled(contacts == nil || importing)
                    } else {
                        Button("Add to Contacts (local)") { add(to: nil) }.disabled(contacts == nil || importing)
                    }
                }
                Text(googleContainer == nil
                     ? "Adds to your default Contacts account. To reach your phone, add your Google account under System Settings → Internet Accounts with Contacts enabled."
                     : "Previewing does not add anyone; only the Add buttons write to Contacts.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }.padding(20)
        }
        .frame(width: 500, height: 510)
        .task(id: url) {
            do { contacts = try await SharedContactReader.shared.load(url: url) }
            catch { self.error = error.localizedDescription }
            googleContainer = await ContactImporter.googleContainer()
        }
    }

    private func add(to container: ContactImporter.Container?) {
        importing = true; importResult = nil
        Task {
            let outcome = await ContactImporter.add(vcardAt: url, to: container)
            importResult = outcome
            importing = false
        }
    }

    private func openInContacts() {
        guard let application = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.AddressBook") else {
            openingError = "Contacts could not be found on this Mac."
            return
        }
        NSWorkspace.shared.open([url], withApplicationAt: application, configuration: NSWorkspace.OpenConfiguration()) { _, error in
            if error != nil { Task { @MainActor in openingError = "Contacts could not open this file. Try revealing it in Finder." } }
        }
    }
}
