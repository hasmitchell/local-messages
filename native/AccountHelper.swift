import AppKit
import Foundation
import Security
import WebKit

// Secrets travel only through private process pipes, never command-line arguments.
// This helper is invoked by gmprobe, not used interactively on its own.
func fail(_ text: String) -> Never {
    FileHandle.standardError.write(Data((text + "\n").utf8))
    exit(1)
}

func keychainQuery(account: String) -> [String: Any] {
    [kSecClass as String: kSecClassGenericPassword,
     kSecAttrService as String: "local.GoogleMessagingAppMac.probe",
     kSecAttrAccount as String: account]
}

@MainActor
final class LoginController: NSObject, NSApplicationDelegate, NSWindowDelegate, WKNavigationDelegate {
    var window: NSWindow!
    var webView: WKWebView!
    var status: NSTextField!
    var submitted = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = self
        webView.translatesAutoresizingMaskIntoConstraints = false

        status = NSTextField(wrappingLabelWithString:
            "Sign in to Google, then choose Continue. Pairing credentials stay in your Mac Keychain.")
        status.translatesAutoresizingMaskIntoConstraints = false
        let button = NSButton(title: "Continue pairing", target: self, action: #selector(continuePairing))
        button.bezelStyle = .rounded
        button.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        content.addSubview(webView)
        content.addSubview(status)
        content.addSubview(button)
        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: content.topAnchor),
            webView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            webView.bottomAnchor.constraint(equalTo: button.topAnchor, constant: -16),
            button.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            button.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
            status.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            status.trailingAnchor.constraint(equalTo: button.leadingAnchor, constant: -16),
            status.centerYAnchor.constraint(equalTo: button.centerYAnchor)
        ])
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 880, height: 720),
                          styleMask: [.titled, .closable, .resizable, .miniaturizable],
                          backing: .buffered, defer: false)
        window.title = "Google Messages — Account pairing prototype"
        window.contentView = content
        window.delegate = self
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        let url = URL(string: "https://accounts.google.com/AccountChooser?continue=https%3A%2F%2Fmessages.google.com%2Fweb%2Fconfig")!
        webView.load(URLRequest(url: url))
    }

    @objc func continuePairing() {
        guard !submitted else { return }
        webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { [weak self] cookies in
            guard let self else { return }
            let names: Set<String> = ["SID", "HSID", "SSID", "OSID", "APISID", "SAPISID",
                "__Secure-1PSIDTS", "__Secure-3PSIDTS", "__Secure-1PSID", "__Secure-3PSID",
                "__Secure-1PAPISID", "__Secure-3PAPISID"]
            let domains: Set<String> = ["google.com", "accounts.google.com", "messages.google.com"]
            var values: [String: String] = [:]
            for cookie in cookies where domains.contains(cookie.domain.trimmingCharacters(in: CharacterSet(charactersIn: "."))) && names.contains(cookie.name) {
                values[cookie.name] = cookie.value
            }
            guard values["SAPISID"] != nil, values["SID"] != nil else {
                self.status.stringValue = "Finish signing in first. If Google rejects this embedded browser, close this window; browser-based pairing needs further work."
                return
            }
            do {
                let data = try JSONSerialization.data(withJSONObject: values)
                self.submitted = true
                FileHandle.standardOutput.write(data)
                NSApp.terminate(nil)
            } catch { fail("Could not prepare the account session.") }
        }
    }

    func windowWillClose(_ notification: Notification) { exit(submitted ? 0 : 2) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        if (error as NSError).code != NSURLErrorCancelled {
            status.stringValue = "Google sign-in could not load. Check connectivity or close the window to cancel."
        }
    }
}

@main
struct AccountHelper {
@MainActor static func main() {
let args = CommandLine.arguments
guard args.count >= 2 else { fail("This helper is managed by gmprobe.") }
switch args[1] {
case "login":
    let app = NSApplication.shared
    let delegate = LoginController()
    app.setActivationPolicy(.regular)
    app.delegate = delegate
    withExtendedLifetime(delegate) { app.run() }
case "get", "put", "has":
    guard args.count == 3 else { fail("Missing archive identifier.") }
    var query = keychainQuery(account: args[2])
    if args[1] == "put" {
        let data = FileHandle.standardInput.readDataToEndOfFile()
        guard !data.isEmpty, data.count < 1_048_576 else { fail("Invalid session length.") }
        let changes = [kSecValueData as String: data]
        var result = SecItemUpdate(query as CFDictionary, changes as CFDictionary)
        if result == errSecItemNotFound {
            query[kSecValueData as String] = data
            query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            query[kSecAttrLabel as String] = "Google Messages local prototype"
            result = SecItemAdd(query as CFDictionary, nil)
        }
        guard result == errSecSuccess else { fail("Keychain could not save the session (\(result)).") }
    } else {
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecReturnData as String] = args[1] == "get"
        var value: CFTypeRef?
        let result = SecItemCopyMatching(query as CFDictionary, &value)
        if result == errSecItemNotFound { exit(3) }
        guard result == errSecSuccess else { fail("Keychain access failed (\(result)).") }
        if args[1] == "get", let data = value as? Data { FileHandle.standardOutput.write(data) }
    }
default: fail("Unknown helper command.")
}
}
}
