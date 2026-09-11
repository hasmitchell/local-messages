import Contacts
import Foundation

struct SharedContact: Identifiable, Sendable {
    struct Field: Identifiable, Sendable {
        let id: Int
        let label: String
        let value: String
    }
    let id: Int
    let name: String
    let organization: String
    let fields: [Field]
}

enum ContactPreviewFailure: LocalizedError {
    case unreadable, tooLarge, invalid
    var errorDescription: String? {
        switch self {
        case .unreadable: "This contact file could not be read."
        case .tooLarge: "This contact file is too large to preview. You can reveal the original in Finder."
        case .invalid: "This file could not be read as a contact card. You can reveal the original in Finder."
        }
    }
}

actor SharedContactReader {
    static let shared = SharedContactReader()
    private let byteLimit = 4 * 1024 * 1024

    func load(url: URL) throws -> [SharedContact] {
        guard url.isFileURL,
              let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              values.isRegularFile == true else { throw ContactPreviewFailure.unreadable }
        guard let size = values.fileSize, size <= byteLimit else { throw ContactPreviewFailure.tooLarge }
        let file: FileHandle
        do { file = try FileHandle(forReadingFrom: url) }
        catch { throw ContactPreviewFailure.unreadable }
        defer { try? file.close() }
        let data: Data
        do { data = try file.read(upToCount: byteLimit + 1) ?? Data() }
        catch { throw ContactPreviewFailure.unreadable }
        guard data.count <= byteLimit else { throw ContactPreviewFailure.tooLarge }
        let contacts: [CNContact]
        do { contacts = try CNContactVCardSerialization.contacts(with: data) }
        catch { throw ContactPreviewFailure.invalid }
        guard !contacts.isEmpty else { throw ContactPreviewFailure.invalid }
        guard contacts.count <= 100 else { throw ContactPreviewFailure.tooLarge }

        // Parse only the received file. Never query or write the user's address book,
        // fetch remote photos, or carry non-Sendable CNContact objects into the UI.
        return contacts.enumerated().map { index, contact in
            var fields: [SharedContact.Field] = []
            func append(_ label: String?, fallback: String, value: String) {
                guard !value.isEmpty else { return }
                let title = label.map { CNLabeledValue<NSString>.localizedString(forLabel: $0) } ?? fallback
                fields.append(.init(id: fields.count, label: title, value: value))
            }
            for phone in contact.phoneNumbers { append(phone.label, fallback: "Phone", value: phone.value.stringValue) }
            for email in contact.emailAddresses { append(email.label, fallback: "Email", value: email.value as String) }
            for address in contact.postalAddresses {
                append(address.label, fallback: "Address", value: CNPostalAddressFormatter.string(from: address.value, style: .mailingAddress))
            }
            for website in contact.urlAddresses { append(website.label, fallback: "Website", value: website.value as String) }
            let name = CNContactFormatter.string(from: contact, style: .fullName) ?? ""
            return SharedContact(id: index, name: name.isEmpty ? (contact.organizationName.isEmpty ? "Shared contact" : contact.organizationName) : name,
                                 organization: contact.organizationName, fields: fields)
        }
    }
}
