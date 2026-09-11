import AppKit
import CryptoKit
import SwiftUI
import UserNotifications

@MainActor
final class MessageNotifications: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    @Published var enabled = UserDefaults.standard.bool(forKey: "notificationsEnabled")
    @Published var previews = UserDefaults.standard.bool(forKey: "notificationPreviews")
    @Published var notifyWhileReading = UserDefaults.standard.bool(forKey: "notifyWhileReading")
    @Published var testResult: String?
    @Published var permissionBlocked = false
    @Published var status = "Notifications off"
    private let center = UNUserNotificationCenter.current()
    private var archiveToken: String?
    private var selectMessage: ((String, String) -> Void)?
    private var replyHandler: ((String, String) -> Void)?
    private var permission: UNAuthorizationStatus = .notDetermined
    private static let messageCategory = "message"

    override init() {
        super.init()
        center.delegate = self
        // Inline replies: the text goes through the ordinary send path.
        let reply = UNTextInputNotificationAction(identifier: "reply", title: "Reply", options: [], textInputButtonTitle: "Send", textInputPlaceholder: "Message")
        center.setNotificationCategories([UNNotificationCategory(identifier: Self.messageCategory, actions: [reply], intentIdentifiers: [], options: [])])
        Task { await refreshSettings() }
    }
    func configure(directory: URL?, select: ((String, String) -> Void)?, reply: ((String, String) -> Void)?) {
        let token = directory.map { Self.token($0.standardizedFileURL.path) }
        if token != archiveToken { center.removeAllPendingNotificationRequests(); center.removeAllDeliveredNotifications() }
        archiveToken = token
        selectMessage = select
        replyHandler = reply
    }
    /// A local notice when a notification reply could not be handed to the phone.
    func deliverFailure(_ title: String, body: String) async {
        guard enabled, permission == .authorized || permission == .provisional else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        try? await center.add(UNNotificationRequest(identifier: "reply-failure-" + UUID().uuidString, content: content, trigger: nil))
    }
    private static func token(_ value: String) -> String { SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined() }
    func refreshSettings() async {
        let settings = await center.notificationSettings()
        permission = settings.authorizationStatus
        permissionBlocked = permission == .denied
        if permissionBlocked { status = "Notifications blocked in macOS Settings" }
        else if !enabled { status = "Notifications off" }
        else if permission == .authorized || permission == .provisional { status = "Notifications on" }
        else { status = "Notifications blocked in macOS Settings" }
    }
    func toggle() {
        if enabled {
            enabled = false
            UserDefaults.standard.set(false, forKey: "notificationsEnabled")
            center.removeAllPendingNotificationRequests()
            center.removeAllDeliveredNotifications()
            status = "Notifications off"
        } else {
            Task {
                do {
                    await refreshSettings()
                    if permissionBlocked { openSettings(); return }
                    NSApp.activate(ignoringOtherApps: true)
                    let allowed = try await center.requestAuthorization(options: [.alert, .sound])
                    enabled = allowed
                    UserDefaults.standard.set(allowed, forKey: "notificationsEnabled")
                    await refreshSettings()
                    if !allowed { status = "Allow notifications in macOS Settings" }
                } catch {
                    let failure = error as NSError
                    UserDefaults.standard.set(failure.domain, forKey: "notificationErrorDomain")
                    UserDefaults.standard.set(failure.code, forKey: "notificationErrorCode")
                    await refreshSettings()
                    if !permissionBlocked { status = "Notification permission could not be requested" }
                }
            }
        }
    }
    func openSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") { NSWorkspace.shared.open(url) }
    }
    func togglePreviews() {
        previews.toggle()
        UserDefaults.standard.set(previews, forKey: "notificationPreviews")
        // Clear previews already handed to Notification Center when hiding them.
        if !previews { center.removeAllDeliveredNotifications() }
    }
    func setNotifyWhileReading(_ value: Bool) {
        notifyWhileReading = value
        UserDefaults.standard.set(value, forKey: "notifyWhileReading")
    }
    func deliver(_ message: MessageRecord, title: String) async {
        guard enabled, let token = archiveToken else { return }
        await refreshSettings()
        guard enabled, archiveToken == token, permission == .authorized || permission == .provisional else { return }
        let content = UNMutableNotificationContent()
        content.title = previews ? String(title.prefix(120)) : "Local Messages"
        content.body = previews ? String(message.preview.prefix(240)) : "You have a new message."
        content.sound = .default
        content.threadIdentifier = Self.token(token + message.conversationID)
        content.categoryIdentifier = Self.messageCategory
        content.userInfo = ["archive": token, "conversation": message.conversationID, "message": message.id]
        let request = UNNotificationRequest(identifier: Self.token(token + ":" + message.id), content: content, trigger: nil)
        do {
            try await center.add(request)
            // A switch can happen while macOS is accepting a notification.
            if archiveToken != token {
                center.removePendingNotificationRequests(withIdentifiers: [request.identifier])
                center.removeDeliveredNotifications(withIdentifiers: [request.identifier])
            }
        }
        catch { status = "Notification could not be shown" }
    }
    func test() {
        Task {
            await refreshSettings()
            guard enabled, permission == .authorized || permission == .provisional else { return }
            let content = UNMutableNotificationContent()
            content.title = "Local Messages"
            content.body = "Notifications are working. This is a local test."
            content.sound = .default
            do {
                try await center.add(UNNotificationRequest(identifier: "local-messages-test", content: content, trigger: nil))
                testResult = "Test accepted by macOS. If no banner appears, check Focus and screen-sharing notification settings."
            }
            catch { testResult = "Test notification could not be shown." }
        }
    }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions { [.banner, .sound] }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let info = response.notification.request.content.userInfo
        let archive = info["archive"] as? String, conversation = info["conversation"] as? String, message = info["message"] as? String
        if response.actionIdentifier == "reply", let text = (response as? UNTextInputNotificationResponse)?.userText {
            await MainActor.run {
                if let archive, archive == self.archiveToken, let conversation { self.replyHandler?(conversation, text) }
            }
            return
        }
        guard response.actionIdentifier == UNNotificationDefaultActionIdentifier else { return }
        await MainActor.run {
            NSApp.activate(ignoringOtherApps: true)
            if let archive, archive == self.archiveToken, let conversation, let message { self.selectMessage?(conversation, message) }
        }
    }
}
