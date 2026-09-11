import AppKit
import Foundation
import Darwin

enum SyncState: String, Decodable, Sendable {
    case local, paused, sleeping, connecting, catchingUp = "catching_up", connected
    case checkingInbox = "checking_inbox", checkingArchive = "checking_archive"
    case reconnecting, incomplete = "catchup_incomplete", pairingRequired = "pairing_required"
    case keychainError = "keychain_error", photosPending = "photos_pending", stopped, unavailable

    var canSend: Bool {
        switch self {
        case .catchingUp, .checkingInbox, .checkingArchive, .connected, .incomplete, .photosPending, .keychainError: true
        default: false
        }
    }
    var label: String {
        switch self {
        case .local: "Local archive"
        case .paused: "Sync paused"
        case .sleeping: "Sync paused during sleep"
        case .connecting: "Connecting to your phone…"
        case .catchingUp: "Catching up…"
        case .checkingInbox, .checkingArchive: "Checking conversations…"
        case .connected: "Connected to your phone"
        case .reconnecting: "Connection interrupted · Retrying…"
        case .incomplete: "Catching up · Some messages pending"
        case .pairingRequired: "Pairing needs attention"
        case .keychainError: "Could not save pairing to Keychain"
        case .photosPending: "Connected · Some attachments pending"
        case .stopped: "Sync stopped"
        case .unavailable: "Sync could not start"
        }
    }
    var help: String {
        switch self {
        case .pairingRequired: "The saved pairing is unavailable or Google signed it out. Open Settings → Reconnect account to verify the original account and phone while keeping saved history."
        case .unavailable: "Another sync may be using this archive, or the bundled sync helper is missing. Pause any terminal import and retry."
        case .keychainError: "Check Keychain access before quitting so refreshed credentials can be saved."
        case .photosPending: "Messages are saved. Photos and contact cards will be retried automatically."
        default: "Messages sync while this app is open. Saved conversations and search work offline. Photos are checked every five minutes."
        }
    }
}

struct SyncStatus: Decodable, Sendable {
    let state: SyncState
    let time: String
    let connection: String?
}

// Owns one child process. A private stdin pipe is a lifetime signal: closing the
// app, switching archives or a crash closes it and shuts the worker down.
@MainActor
final class SyncController: NSObject {
    private let onState: (SyncState) -> Void
    private let workerURL: URL
    private var retiring: [Process] = []
    private var process: Process?
    private var lifetime: Pipe?
    private var output: Pipe?
    private var reader: Task<Void, Never>?
    private var generation = UUID()
    private var directory: URL?
    private var enabled = false
    private var sleeping = false
    private var terminalState = false
    private var connectionID: String?

    init(workerURL: URL = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/gmprobe"), onState: @escaping (SyncState) -> Void) {
        self.workerURL = workerURL
        self.onState = onState
        super.init()
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(willSleep), name: NSWorkspace.willSleepNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(didWake), name: NSWorkspace.didWakeNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(willQuit), name: NSApplication.willTerminateNotification, object: nil)
    }

    func configure(directory: URL?, enabled: Bool) {
        stop()
        self.directory = directory
        self.enabled = enabled
        guard directory != nil else { onState(.local); return }
        guard enabled else { onState(.paused); return }
        if sleeping { onState(.sleeping) } else { launch() }
    }

    var isStopped: Bool { process == nil && retiring.allSatisfy { !$0.isRunning } }

    func send(_ command: SendCommand) throws {
        guard let process, process.isRunning, let lifetime, let connectionID else { throw CocoaError(.fileWriteUnknown) }
        var bound = command
        bound.connection = connectionID
        var data = try JSONEncoder().encode(bound)
        data.append(0x0a)
        // A private pipe keeps text and conversation IDs out of argv and logs.
        try lifetime.fileHandleForWriting.write(contentsOf: data)
    }

    private func launch() {
        guard let directory, enabled, !sleeping, process == nil else { return }
        retiring.removeAll { !$0.isRunning }
        if !retiring.isEmpty {
            let token = generation
            onState(.connecting)
            Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(250))
                guard let self, self.generation == token else { return }
                self.launch()
            }
            return
        }
        let worker = workerURL
        guard FileManager.default.isExecutableFile(atPath: worker.path) else { onState(.unavailable); return }
        let token = UUID()
        generation = token
        terminalState = false
        let child = Process()
        let input = Pipe(), stdout = Pipe()
        child.executableURL = worker
        child.arguments = ["watch", "--data", directory.path, "--commands-stdin", "--media", "photos-and-contacts", "--media-budget-mib", "256"]
        child.standardInput = input
        child.standardOutput = stdout
        child.standardError = FileHandle.nullDevice
        child.terminationHandler = { [weak self] _ in
            Task { @MainActor in
                guard let self, self.generation == token else { return }
                self.process = nil
                self.lifetime = nil
                if !self.terminalState { self.onState(.unavailable) }
            }
        }
        do {
            try child.run()
            process = child
            lifetime = input
            output = stdout
            try? input.fileHandleForReading.close()
            try? stdout.fileHandleForWriting.close()
            onState(.connecting)
            reader = Task { [weak self] in
                do {
                    // The worker emits only this small allowlisted status schema.
                    for try await line in stdout.fileHandleForReading.bytes.lines {
                        guard !Task.isCancelled, let self, self.generation == token else { return }
                        guard line.utf8.count < 512, let data = line.data(using: .utf8),
                              let status = try? JSONDecoder().decode(SyncStatus.self, from: data) else { continue }
                        if status.state == .pairingRequired { self.terminalState = true }
                        self.connectionID = status.connection
                        self.onState(status.state)
                    }
                } catch { /* Process termination closes the pipe. */ }
            }
        } catch { onState(.unavailable) }
    }

    private func stop() {
        generation = UUID()
        connectionID = nil
        reader?.cancel()
        reader = nil
        try? lifetime?.fileHandleForWriting.close()
        lifetime = nil
        try? output?.fileHandleForReading.close()
        output = nil
        if let process, process.isRunning {
            retiring.append(process)
            process.terminate()
            // The Go worker also has its own five-second shutdown deadline.
            Task {
                try? await Task.sleep(for: .seconds(6))
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            }
        }
        process = nil
    }
    @objc private func willSleep(_ note: Notification) { sleeping = true; stop(); if enabled { onState(.sleeping) } }
    @objc private func didWake(_ note: Notification) { sleeping = false; if enabled { launch() } }
    @objc private func willQuit(_ note: Notification) { enabled = false; stop() }
}
