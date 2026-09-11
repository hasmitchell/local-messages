import Contacts
import Foundation

// Writes a received vCard into macOS Contacts. When the Mac has a Google
// account with Contacts enabled, that account's container is offered so the
// person reaches Google Contacts and the phone; nothing is read back.
enum ContactImporter {
    struct Container: Identifiable, Equatable, Sendable { let id: String; let name: String }

    static func googleContainer() async -> Container? {
        let store = CNContactStore()
        guard CNContactStore.authorizationStatus(for: .contacts) != .denied,
              let containers = try? store.containers(matching: nil) else { return nil }
        let google = containers.first { container in
            container.type == .cardDAV && (container.name.localizedCaseInsensitiveContains("google") || container.name.localizedCaseInsensitiveContains("gmail"))
        }
        return google.map { Container(id: $0.identifier, name: $0.name) }
    }

    static func add(vcardAt url: URL, to container: Container?) async -> String {
        let store = CNContactStore()
        do {
            guard try await store.requestAccess(for: .contacts) else {
                return "Contacts access was not allowed. You can allow Local Messages under System Settings → Privacy & Security → Contacts."
            }
        } catch { return "Contacts access could not be requested." }
        guard let data = try? Data(contentsOf: url), data.count <= 4 * 1024 * 1024,
              let parsed = try? CNContactVCardSerialization.contacts(with: data), !parsed.isEmpty else {
            return "This card could not be read as contacts."
        }
        let request = CNSaveRequest()
        var names: [String] = []
        for contact in parsed.prefix(100) {
            guard let mutable = contact.mutableCopy() as? CNMutableContact else { continue }
            request.add(mutable, toContainerWithIdentifier: container?.id)
            let name = CNContactFormatter.string(from: contact, style: .fullName) ?? contact.organizationName
            names.append(name.isEmpty ? "Contact" : name)
        }
        do { try store.execute(request) }
        catch { return "Contacts could not save this card" + (container.map { " to \($0.name)" } ?? "") + ". Try Open in Contacts… instead." }
        let destination = container.map { $0.name } ?? "Contacts"
        return "Added \(names.joined(separator: ", ")) to \(destination)."
    }
}
