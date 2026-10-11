import AppKit
import Contacts

/// Messages, WhatsApp and Mail. Nothing is sent without a spoken "yes".
@MainActor
enum Messaging {
    enum Channel { case iMessage, whatsApp, email }

    struct Person { let name: String; let phones: [String]; let emails: [String] }

    /// Best contact match for a spoken name ("mom", "rahul", "rahul sharma").
    static func find(_ spoken: String) async -> Person? {
        let status = CNContactStore.authorizationStatus(for: .contacts)
        if status == .notDetermined { _ = try? await CNContactStore().requestAccess(for: .contacts) }
        let store = CNContactStore()
        let keys = [CNContactGivenNameKey, CNContactFamilyNameKey, CNContactNicknameKey, CNContactPhoneNumbersKey,
                    CNContactEmailAddressesKey, CNContactOrganizationNameKey] as [CNKeyDescriptor]
        let q = spoken.lowercased()
        var best: (CNContact, Int)?
        let request = CNContactFetchRequest(keysToFetch: keys)
        try? store.enumerateContacts(with: request) { c, _ in
            let full = "\(c.givenName) \(c.familyName)".lowercased().trimmingCharacters(in: .whitespaces)
            let names = [full, c.givenName.lowercased(), c.nickname.lowercased(), c.familyName.lowercased(), c.organizationName.lowercased()].filter { !$0.isEmpty }
            var score = 0
            if names.contains(q) { score = 100 }
            else if full.hasPrefix(q) || q.hasPrefix(c.givenName.lowercased() + " ") { score = 60 }
            else if let d = names.map({ editDistance($0, q) }).min(), d <= max(1, q.count / 4) { score = 40 - d }
            if score > (best?.1 ?? 0) { best = (c, score) }
        }
        guard let c = best?.0 else { return nil }
        let name = [c.givenName, c.familyName].filter { !$0.isEmpty }.joined(separator: " ")
        return Person(name: name.isEmpty ? c.organizationName : name,
                      phones: c.phoneNumbers.map { $0.value.stringValue },
                      emails: c.emailAddresses.map { $0.value as String })
    }

    static func sendIMessage(_ body: String, to handle: String) async -> Bool {
        let script = """
            tell application "Messages"
                set svc to 1st account whose service type = iMessage
                send "\(escape(body))" to participant "\(escape(handle))" of svc
            end tell
            """
        return await Script.run(script, timeout: 20) != nil
    }

    /// Opens the WhatsApp chat with the text filled in; the caller presses Return to send after confirmation.
    static func openWhatsApp(_ body: String, phone: String) -> Bool {
        let digits = phone.filter(\.isNumber)
        var c = URLComponents(string: "whatsapp://send")!
        c.queryItems = [.init(name: "phone", value: digits), .init(name: "text", value: body)]
        guard let url = c.url else { return false }
        return NSWorkspace.shared.open(url)
    }

    static func composeEmail(to: String?, subject: String?, body: String?) -> Bool {
        var c = URLComponents()
        c.scheme = "mailto"
        c.path = to ?? ""
        var items: [URLQueryItem] = []
        if let subject { items.append(.init(name: "subject", value: subject)) }
        if let body { items.append(.init(name: "body", value: body)) }
        c.queryItems = items.isEmpty ? nil : items
        guard let url = c.url else { return false }
        return NSWorkspace.shared.open(url)
    }

    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }
}
